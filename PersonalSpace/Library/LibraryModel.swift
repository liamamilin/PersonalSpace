import AppKit
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var objects: [PersonalObject] = []
    @Published var selectedObjectID: String?
    @Published var linkedObjects: [PersonalObject] = []
    @Published var showObjectEditor = false
    @Published var objectBeingEdited: PersonalObject?
    @Published var showLinkSheet = false
    @Published var showFilePicker = false
    @Published var archivingID: String?
    @Published var originalURL: URL?
    @Published var managedURL: URL?
    @Published var previewIsManaged = false
    @Published var originalError: String?
    @Published var managedError: String?
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
    private var started = false
    private var managedStore: ManagedFileStore?
    private var previewRoot: URL?
    private var queryGeneration = 0

    var selectedFile: LibraryFile? { files.first { $0.id == selectedFileID } }
    var currentObjectID: String? {
        selectedSourceID.hasPrefix("object:") ? String(selectedSourceID.dropFirst(7)) : nil
    }
    var isObjectsList: Bool { selectedSourceID == "objects" }
    var selectedObject: PersonalObject? {
        objects.first { $0.id == (currentObjectID ?? selectedObjectID) }
    }
    var query: FileQuery {
        let isSource = !["all", "objects", "managed"].contains(selectedSourceID) && currentObjectID == nil
        return FileQuery(search: isObjectsList ? "" : search, sourceID: isSource ? selectedSourceID : nil,
            objectID: currentObjectID, managedOnly: selectedSourceID == "managed",
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
        do { managedStore = try ManagedFileStore.applicationStore() }
        catch { errorMessage = "托管目录无法访问，文件搜索仍可使用。" }
    }

    func start() async {
        guard !started else { return }
        started = true
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
            let newObjects = try await database.objects()
            let result = try await database.files(request)
            guard generation == queryGeneration, !Task.isCancelled else { return }
            sources = newSources
            objects = newObjects
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
            let existing: FolderSource?
            if let source { existing = source }
            else { existing = try await database.findSource(path: canonicalPath) }
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

    func preparePreview(preferManaged: Bool = false) {
        releasePreview()
        originalError = nil
        managedError = nil
        previewError = nil
        guard let file = selectedFile else { return }
        if file.isAvailable, let source = sources.first(where: { $0.id == file.sourceID }) {
            do {
                let access = try FolderAccess.resolve(source)
                previewRoot = access.url
                originalURL = try FolderAccess.fileURL(relativePath: file.relativePath, root: access.url)
            } catch {
                originalError = (error as? AccessError)?.errorDescription ?? AccessError.authorization.errorDescription
                previewRoot?.stopAccessingSecurityScopedResource()
                previewRoot = nil
            }
        } else { originalError = file.sourceError ?? AccessError.missing.errorDescription }
        if let relative = file.managedCopyPath {
            do {
                guard let managedStore else { throw AccessError.missing }
                managedURL = try managedStore.url(for: relative)
            } catch { managedError = "托管副本不可用，请检查应用数据目录。" }
        }
        if preferManaged || originalURL == nil {
            previewURL = managedURL ?? originalURL
            previewIsManaged = managedURL != nil
        } else {
            previewURL = originalURL
            previewIsManaged = false
        }
        if previewURL == nil { previewError = managedError ?? originalError }
    }

    private func releasePreview() {
        previewURL = nil
        originalURL = nil
        managedURL = nil
        previewIsManaged = false
        previewRoot?.stopAccessingSecurityScopedResource()
        previewRoot = nil
    }

    func quickLook(preferManaged: Bool = false) {
        preparePreview(preferManaged: preferManaged)
        if previewURL != nil { showQuickLook = true }
        else if selectedFile != nil { errorMessage = previewError }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if error != nil {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "无法用默认应用打开文件，请在 Finder 中检查文件类型和默认应用。"
                }
            }
        }
    }

    func openSelected() {
        preparePreview()
        guard previewURL != nil else { errorMessage = previewError; return }
        open(previewURL)
    }

    func openOriginal() {
        preparePreview()
        guard originalURL != nil else { errorMessage = originalError; return }
        open(originalURL)
    }

    func openManagedCopy() {
        preparePreview(preferManaged: true)
        guard managedURL != nil else { errorMessage = managedError ?? "尚未保存托管副本。"; return }
        open(managedURL)
    }

    func revealSelected() {
        preparePreview()
        guard let originalURL else { errorMessage = originalError; return }
        NSWorkspace.shared.activateFileViewerSelecting([originalURL])
    }

    func createObject() {
        errorMessage = nil
        objectBeingEdited = nil
        showObjectEditor = true
    }

    func editObject(_ object: PersonalObject) {
        errorMessage = nil
        objectBeingEdited = object
        showObjectEditor = true
    }

    func showObject(_ id: String) {
        selectedObjectID = id
        selectedFileID = nil
        search = ""
        selectedSourceID = "object:" + id
    }

    func saveObject(id: String, name: String, kind: String, notes: String) async -> Bool {
        guard let database else { return false }
        do {
            try await database.saveObject(id: id, name: name, kind: kind, notes: notes)
            showObject(id)
            await reload()
            return true
        } catch {
            errorMessage = "保存对象失败。请填写名称并重试。"
            return false
        }
    }

    func reloadLinkedObjects() async {
        guard let database, let id = selectedFileID else { linkedObjects = []; return }
        do {
            let result = try await database.objectsForItem(id)
            if selectedFileID == id { linkedObjects = result }
        } catch { errorMessage = "读取对象关联失败，请重试。" }
    }

    func linkItems(_ ids: [String], to objectID: String) async -> Bool {
        guard let database else { return false }
        do {
            try await database.linkItems(ids, to: objectID)
            await reload()
            await reloadLinkedObjects()
            return true
        } catch { errorMessage = "关联资料失败，请重试。"; return false }
    }

    func unlink(_ fileID: String, from objectID: String) async {
        guard let database else { return }
        do {
            try await database.unlinkItem(fileID, from: objectID)
            await reload()
            await reloadLinkedObjects()
        } catch { errorMessage = "解除关联失败。原文件未受影响。" }
    }

    func availableFiles(search: String, managedOnly: Bool) async throws -> [LibraryFile] {
        guard let database else { return [] }
        return try await database.files(FileQuery(search: search, managedOnly: managedOnly, limit: 500)).files
    }

    func showInLibrary(_ file: LibraryFile) async {
        selectedSourceID = sources.contains(where: { $0.id == file.sourceID }) ? file.sourceID : "managed"
        search = file.name
        await reload()
        selectedFileID = file.id
    }

    func archiveSelected() async {
        guard let database, let store = managedStore, let file = selectedFile,
              file.managedCopyPath == nil, archivingID == nil,
              let source = sources.first(where: { $0.id == file.sourceID }) else { return }
        archivingID = file.id
        defer { archivingID = nil }
        do {
            let access = try FolderAccess.resolve(source)
            let original: URL
            do { original = try FolderAccess.fileURL(relativePath: file.relativePath, root: access.url) }
            catch { access.url.stopAccessingSecurityScopedResource(); throw error }
            let result = try await Task.detached(priority: .utility) {
                defer { access.url.stopAccessingSecurityScopedResource() }
                return try store.copy(sourceURL: original)
            }.value
            do {
                try await database.saveManagedCopy(itemID: file.id, relativePath: result.relativePath, sha256: result.sha256)
            } catch {
                try store.discardUncommittedCopy(result.relativePath)
                throw error
            }
            await reload()
            if selectedFileID == file.id { preparePreview() }
        } catch {
            errorMessage = "未能保存托管副本。请检查原文件权限和磁盘空间后重试，原件保持不变。"
        }
    }
}
