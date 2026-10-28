import AppKit
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var sources: [FolderSource] = []
    @Published var files: [LibraryFile] = []
    @Published var total = 0
    @Published var search = ""
    @Published var selectedSourceID = "all"
    @Published var selectedFileID: String?
    @Published var sort: FileSort = .name
    @Published var ascending = true
    @Published var limit = 500
    @Published var scanning: [String: Int] = [:]
    @Published var errorMessage: String?
    @Published var previewURL: URL?
    @Published var previewError: String?
    @Published var showQuickLook = false
    @Published var searchFocusRequest = 0
    @Published var storageUnavailable = false
    private let database: LibraryDatabase?
    private var scanTasks: [String: Task<Void, Never>] = [:]
    private var previewRoot: URL?
    private var queryGeneration = 0

    var selectedFile: LibraryFile? { files.first { $0.id == selectedFileID } }
    var query: FileQuery {
        FileQuery(search: search, sourceID: selectedSourceID == "all" ? nil : selectedSourceID,
                  sort: sort, ascending: ascending, limit: limit)
    }
    var isScanning: Bool { !scanning.isEmpty }

    init() {
        do { database = try LibraryDatabase.applicationDatabase() }
        catch {
            database = nil
            storageUnavailable = true
            errorMessage = "无法打开本地资料库。请检查磁盘空间和应用数据目录的访问权限后重新启动。"
        }
    }

    func start() async {
        await reload()
        for source in sources { refresh(source) }
    }

    func reload() async {
        guard let database else { return }
        queryGeneration += 1
        let generation = queryGeneration
        let request = query
        do {
            let newSources = try await database.sources()
            let result = try await database.files(request)
            guard generation == queryGeneration, !Task.isCancelled else { return }
            sources = newSources
            files = result.files
            total = result.total
            if let id = selectedFileID, !files.contains(where: { $0.id == id }) {
                selectedFileID = nil
            }
        } catch { errorMessage = "读取资料库失败，请重试。" }
    }

    func addFolders(replacing source: FolderSource? = nil) {
        guard database != nil else { return }
        let panel = NSOpenPanel()
        panel.title = source == nil ? "添加资料来源" : "重新授权来源"
        panel.message = source == nil ? "文件保留在原位置，PersonalSpace 仅建立本地索引。" : "请重新选择原来的文件夹，恢复访问权限。"
        panel.prompt = source == nil ? "添加文件夹" : "重新授权"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = source == nil
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                await saveFolder(url, replacing: source)
            }
        }
    }

    private func saveFolder(_ url: URL, replacing source: FolderSource?) async {
        guard let database else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey])
            guard values.isPackage != true, values.isSymbolicLink != true else { throw AccessError.authorization }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            if let source, canonicalPath != URL(fileURLWithPath: source.path).resolvingSymlinksInPath().path {
                errorMessage = "请重新选择原来源文件夹。添加其它位置请使用「添加文件夹」。"
                return
            }
            let existing = source ?? sources.first { $0.path == canonicalPath }
            let id = existing?.id ?? UUID().uuidString
            guard scanning[id] == nil else { return }
            let bookmark = try FolderAccess.bookmark(for: url)
            try await database.saveSource(id: id, name: url.lastPathComponent, path: canonicalPath, bookmark: bookmark)
            await reload()
            if let saved = sources.first(where: { $0.id == id }) { refresh(saved) }
        } catch { errorMessage = "无法保存文件夹授权。请重新选择可访问的普通文件夹。" }
    }

    func refreshAll() {
        for source in sources { refresh(source) }
    }

    func refresh(_ source: FolderSource) {
        guard let database, scanTasks[source.id] == nil else { return }
        scanning[source.id] = 0
        scanTasks[source.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let access = try FolderAccess.resolve(source)
                do {
                    if let bookmark = access.renewedBookmark {
                        try await database.saveSource(id: source.id, name: access.url.lastPathComponent,
                            path: access.url.path, bookmark: bookmark)
                    }
                } catch {
                    access.url.stopAccessingSecurityScopedResource()
                    throw error
                }
                let worker = Task.detached(priority: .utility) { [weak self] in
                    defer { access.url.stopAccessingSecurityScopedResource() }
                    try FolderScanner.scan(root: access.url, sourceID: source.id, database: database) { [weak self] count in
                        Task { @MainActor [weak self] in
                            guard let self, self.scanning[source.id] != nil else { return }
                            self.scanning[source.id] = count
                            await self.reload()
                        }
                    }
                }
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
            } catch is CancellationError {
                // A partial scan never invalidates previously indexed files.
            } catch {
                do {
                    try await database.setSourceError(source.id,
                        message: (error as? AccessError)?.errorDescription ?? "无法访问文件夹，请重新授权后刷新。")
                } catch { self.errorMessage = "扫描状态保存失败，请重试。" }
            }
            self.scanning[source.id] = nil
            self.scanTasks[source.id] = nil
            await self.reload()
            if self.selectedFile?.sourceID == source.id { self.preparePreview() }
        }
    }

    func cancelScan(_ source: FolderSource) { scanTasks[source.id]?.cancel() }

    func remove(_ source: FolderSource) async {
        guard let database else { return }
        if let task = scanTasks[source.id] {
            task.cancel()
            await task.value
        }
        if selectedFile?.sourceID == source.id { releasePreview() }
        do {
            try await database.removeSource(source.id)
            if selectedSourceID == source.id { selectedSourceID = "all" }
            await reload()
        } catch { errorMessage = "移除来源失败，请重试。原文件未受影响。" }
    }

    func preparePreview() {
        releasePreview()
        previewError = nil
        guard let file = selectedFile, let source = sources.first(where: { $0.id == file.sourceID }) else { return }
        guard file.isAvailable else { previewError = AccessError.missing.errorDescription; return }
        do {
            let access = try FolderAccess.resolve(source)
            previewRoot = access.url
            previewURL = try FolderAccess.fileURL(relativePath: file.relativePath, root: access.url)
        } catch {
            previewError = FileManager.default.fileExists(atPath: file.fullPath)
                ? AccessError.authorization.errorDescription : AccessError.missing.errorDescription
            releasePreview()
        }
    }

    private func releasePreview() {
        previewURL = nil
        previewRoot?.stopAccessingSecurityScopedResource()
        previewRoot = nil
    }

    func quickLook() {
        preparePreview()
        if previewURL != nil { showQuickLook = true }
        else if selectedFile != nil { errorMessage = previewError }
    }

    func openSelected() {
        preparePreview()
        guard let previewURL else {
            if selectedFile != nil { errorMessage = previewError }
            return
        }
        NSWorkspace.shared.open(previewURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil {
                Task { @MainActor [weak self] in self?.errorMessage = "无法用默认应用打开此文件，请在 Finder 中检查文件类型和默认应用。" }
            }
        }
    }

    func revealSelected() {
        preparePreview()
        guard let previewURL else {
            if selectedFile != nil { errorMessage = previewError }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([previewURL])
    }
}
