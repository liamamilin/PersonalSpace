import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryModel: ObservableObject {
    @Published var matters: [MatterRecord] = []
    @Published var actions: [ActionRecord] = []
    @Published var inspectorToggleRequest = 0
    @Published var selectedMatterID: String?
    @Published var selectedActionID: String?
    @Published var matterFacts: [FactRecord] = []
    @Published var matterFiles: [LibraryFile] = []
    @Published var pendingActionIDs: Set<String> = []
    @Published private(set) var reschedulingActionIDs: Set<String> = []
    @Published var pendingReminderDates: [String: Date] = [:]
    @Published var deliveredActionIDs: Set<String> = []
    @Published var reminderMessage: String?
    @Published var showMatterEditor = false
    @Published var matterDraft = MatterDraft()
    @Published var matterObjectSelectionMessage: String?
    let reminders: ReminderController
    let photoLibrary = PhotoLibraryController()
    @Published var photoPreviewImage: NSImage?
    @Published var showPhotoPreview = false
    @Published var backupBusy = false
    @Published var backupMessage: String?
    @Published var restoredLibrary: RestoredLibrary?
    @Published var backupCandidate: BackupCandidate?
    @Published var verifiedBackup: BackupCandidate?
    private var backupPreviewDirectory: URL?
    @Published private(set) var pendingLibrary: LibraryLocation?
    @Published private(set) var retainedLibrary: LibraryLocation?
    private(set) var libraryLocation: LibraryLocation?
    private var librarySelection: ActiveLibrary?
    var openLibraryWindow: (() -> Void)?
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
    @Published var searchBody = false
    @Published var indexingID: String?
    @Published var selectedSourceID = "all"
    @Published var selectedFileID: String?
    @Published var sort: FileSort = .name
    @Published var ascending = true
    @Published var limit = 500
    @Published var scanning: [String: Int] = [:]
    @Published private(set) var monitoredSourceIDs: Set<String> = []
    @Published private(set) var monitoringErrors: [String: String] = [:]
    @Published var errorMessage: String?
    @Published var previewURL: URL?
    @Published var previewError: String?
    @Published var showQuickLook = false
    @Published var searchFocusRequest = 0
    @Published var storageUnavailable = false
    @Published var inboxCount = 0
    @Published var importingTotal = 0
    @Published var importCompleted = 0
    @Published var importMessage: String?
    @Published var importFailures: [String] = []
    @Published var filePendingRemoval: LibraryFile?
    @Published var removingFileID: String?
    @Published var pendingCopyRemoval: String?
    @Published private var loadingDrop = false
    private let database: LibraryDatabase?
    private var scanTasks: [String: Task<Void, Never>] = [:]
    private var folderWatchers: [String: (watcher: FolderWatcher, root: URL)] = [:]
    private var sourceDebounces: [String: Task<Void, Never>] = [:]
    private var sourceChangeStartedAt: [String: ContinuousClock.Instant] = [:]
    private var refreshAfterScan: Set<String> = []
    private var started = false
    private var managedStore: ManagedFileStore?
    private var previewRoot: URL?
    private var queryGeneration = 0

    var selectedFile: LibraryFile? { files.first { $0.id == selectedFileID } }
    var selectedMatter: MatterRecord? { matters.first { $0.id == selectedMatterID } }
    var isMattersList: Bool { selectedSourceID == "matters" }
    var isActionsList: Bool { selectedSourceID == "actions" }
    var isPhotosList: Bool { selectedSourceID == PhotoLibraryController.sourceID }
    var isInbox: Bool { selectedSourceID == "inbox" }
    var isImporting: Bool { importingTotal > 0 || loadingDrop }
    var isFileList: Bool { !isObjectsList && !isMattersList && !isActionsList }
    var currentObjectID: String? {
        selectedSourceID.hasPrefix("object:") ? String(selectedSourceID.dropFirst(7)) : nil
    }
    var isObjectsList: Bool { selectedSourceID == "objects" }
    var selectedObject: PersonalObject? {
        objects.first { $0.id == (currentObjectID ?? selectedObjectID) }
    }
    var query: FileQuery {
        let isSource = !["all", "objects", "managed", "matters", "actions", "inbox"].contains(selectedSourceID) && currentObjectID == nil
        return FileQuery(search: isObjectsList ? "" : search, sourceID: isSource ? selectedSourceID : nil,
            objectID: currentObjectID, managedOnly: selectedSourceID == "managed", inboxOnly: isInbox, searchBody: searchBody,
            sort: sort, ascending: ascending, limit: limit)
    }
    var hasInspectorSelection: Bool {
        if isObjectsList { return selectedObject != nil }
        if isActionsList { return selectedActionID != nil && selectedMatter != nil }
        if isMattersList { return selectedMatter != nil }
        return selectedFile != nil
    }
    var isScanning: Bool { !scanning.isEmpty }

    init(database suppliedDatabase: LibraryDatabase? = nil) {
        var opened: LibraryDatabase?
        var location: LibraryLocation?
        var selection: ActiveLibrary?
        var openingError: String?
        do {
            if let suppliedDatabase { opened = suppliedDatabase }
            else {
                let active = try ActiveLibrary.application()
                selection = active
                let chosen = try active.current()
                location = chosen
                opened = try LibraryDatabase(path: chosen.databaseURL.path)
            }
        }
        catch { openingError = "无法打开活动资料库。已有资料库保留，请检查磁盘和资料库位置。" }
        database = opened
        libraryLocation = location
        librarySelection = selection
        reminders = ReminderController(libraryID: location?.id ?? "original")
        if let location { managedStore = ManagedFileStore(root: location.vault) }
        else if suppliedDatabase != nil { managedStore = try? ManagedFileStore.applicationStore() }
        storageUnavailable = opened == nil
        errorMessage = openingError
        refreshLibrarySelection()
        reminders.onOpenAction = { [weak self] id in
            guard let self else { return }
            self.openLibraryWindow?()
            NSApp.activate(ignoringOtherApps: true)
            Task { await self.openAction(id) }
        }
        reminders.onOtherLibraryReminder = { [weak self] in
            guard let self else { return }
            self.openLibraryWindow?()
            NSApp.activate(ignoringOtherApps: true)
            self.errorMessage = "此提醒来自另一份保留的资料库，请在「设置 → 备份」中切回对应资料库查看。"
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        await refreshPhotosAuthorization()
        await reload()
        await refreshReminderStatus()
        // View reloads can supersede the initial published query. Restore watches
        // from storage even when that query has not populated the sidebar yet.
        guard let database else { return }
        do {
            for source in try await database.sources() {
                guard !source.needsAuthorization else {
                    monitoringErrors[source.id] = "需要重新授权后才能自动更新。"
                    continue
                }
                await startMonitoring(source)
                refresh(source)
            }
        } catch { errorMessage = "恢复来源自动更新失败，请重新启动应用。" }
    }

    isolated deinit {
        for (_, watch) in folderWatchers {
            watch.watcher.stop()
            watch.root.stopAccessingSecurityScopedResource()
        }
        for task in sourceDebounces.values { task.cancel() }
        for task in scanTasks.values { task.cancel() }
    }

    private func startMonitoring(_ source: FolderSource) async {
        guard folderWatchers[source.id] == nil else { return }
        do {
            let access = try FolderAccess.resolve(source)
            do {
                let watcher = try FolderWatcher(root: access.url) { [weak self] in
                    self?.sourceChanged(source)
                }
                if let bookmark = access.renewedBookmark, let database {
                    try await database.saveSource(id: source.id, name: access.url.lastPathComponent,
                        path: access.url.path, bookmark: bookmark)
                }
                folderWatchers[source.id] = (watcher, access.url)
                monitoredSourceIDs.insert(source.id)
                monitoringErrors[source.id] = nil
            } catch {
                access.url.stopAccessingSecurityScopedResource()
                throw error
            }
        } catch {
            monitoringErrors[source.id] = "自动更新未开启，请重新授权来源；仍可手动刷新。"
        }
    }

    private func stopMonitoring(_ id: String) {
        sourceDebounces.removeValue(forKey: id)?.cancel()
        sourceChangeStartedAt[id] = nil
        refreshAfterScan.remove(id)
        if let watch = folderWatchers.removeValue(forKey: id) {
            watch.watcher.stop()
            watch.root.stopAccessingSecurityScopedResource()
        }
        monitoredSourceIDs.remove(id)
        monitoringErrors[id] = nil
    }

    private func sourceChanged(_ source: FolderSource) {
        let id = source.id
        guard folderWatchers[id] != nil else { return }
        let now = ContinuousClock.now
        let firstChange = sourceChangeStartedAt[id] ?? now
        sourceChangeStartedAt[id] = firstChange
        // Keep the quiet-period debounce, but do not starve a continuously busy
        // source. refresh(_:) already coalesces changes while a scan is running.
        let deadline = min(now.advanced(by: .seconds(1)), firstChange.advanced(by: .seconds(5)))
        sourceDebounces[id]?.cancel()
        sourceDebounces[id] = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self else { return }
            self.sourceDebounces[id] = nil
            self.sourceChangeStartedAt[id] = nil
            guard self.folderWatchers[id] != nil else { return }
            self.refresh(source)
        }
    }

    func reload() async {
        guard let database else { return }
        queryGeneration += 1
        let generation = queryGeneration
        let request = query
        do {
            let newSources = try await database.sources()
            let newObjects = try await database.objects()
            let newMatters = try await database.matters()
            let newActions = try await database.actions()
            let result = try await database.files(request)
            let pendingCount = try await database.files(FileQuery(inboxOnly: true, limit: 0)).total
            guard generation == queryGeneration, !Task.isCancelled else { return }
            sources = newSources
            objects = newObjects
            matters = newMatters
            actions = newActions
            files = result.files
            total = result.total
            inboxCount = pendingCount
            if let id = selectedFileID, !files.contains(where: { $0.id == id }) {
                selectedFileID = nil
            }
            if selectedMatterID != nil { await loadMatterDetails() }
        } catch {
            // A SwiftUI search/navigation task may be superseded during an async GRDB read.
            guard generation == queryGeneration, !Task.isCancelled else { return }
            errorMessage = "读取资料库失败，请重试。"
        }
    }

    func addFolders(replacing source: FolderSource? = nil) {
        guard database != nil else { return }
        let panel = NSOpenPanel()
        panel.title = source == nil ? "添加资料来源" : "重新授权来源"
        panel.message = source == nil ? "文件保留在原位置，PersonalSpace 仅建立本地索引。" :
            (source?.needsAuthorization == true ? "请选择与此来源对应的文件夹；新电脑上的路径可以不同，将保留原资料关联。" : "请重新选择原来的文件夹，恢复访问权限。")
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

    func chooseImportFiles() {
        guard !storageUnavailable, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "收纳文件"
        panel.message = "复制到 PersonalSpace 托管保存。原文件保持不变，收纳后可在「待整理」中预览和关联。"
        panel.prompt = "收纳文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    func receiveDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !storageUnavailable, !isImporting, !providers.isEmpty else { return false }
        loadingDrop = true
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else { url = nil }
                        continuation.resume(returning: url?.isFileURL == true ? url : nil)
                    }
                }
                if let url { urls.append(url) }
            }
            loadingDrop = false
            guard urls.count == providers.count else {
                errorMessage = "无法读取拖入的文件。请从 Finder 拖入普通文件，或使用「收纳文件」。"
                return
            }
            importFiles(urls)
        }
        return true
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> Bool {
        guard let database, let store = managedStore, !isImporting,
              !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        // Hold the panel/drop's temporary sandbox access until all copying has completed.
        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        importingTotal = urls.count
        importCompleted = 0
        importFailures = []
        importMessage = nil
        selectedSourceID = "inbox"
        selectedFileID = nil
        search = ""
        Task {
            defer {
                scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                importingTotal = 0
            }
            var importedIDs: [String] = []
            for url in urls {
                do {
                    let id = try await store.importFile(sourceURL: url, database: database)
                    importedIDs.append(id)
                    await reload()
                    if isInbox { selectedFileID = id }
                } catch {
                    importFailures.append(url.lastPathComponent + "：" + error.localizedDescription)
                }
                importCompleted += 1
            }
            importMessage = "已收纳 \(importedIDs.count) 份文件" + (importFailures.isEmpty ? "，原文件保持不变。" : "，\(importFailures.count) 份未收纳。")
            await reload()
        }
        return true
    }

    private func saveFolder(_ url: URL, replacing source: FolderSource?) async {
        guard let database else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey])
            guard values.isPackage != true, values.isSymbolicLink != true else { throw AccessError.authorization }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            if let source, !source.needsAuthorization,
               canonicalPath != URL(fileURLWithPath: source.path).resolvingSymlinksInPath().path {
                errorMessage = "请重新选择原来源文件夹。添加其它位置请使用「添加文件夹」。"
                return
            }
            let existing: FolderSource?
            if let source { existing = source }
            else { existing = try await database.findSource(path: canonicalPath) }
            let id = existing?.id ?? UUID().uuidString
            guard scanning[id] == nil else { return }
            let bookmark = try FolderAccess.bookmark(for: url)
            if source != nil {
                try await database.reauthorizeSource(id: id, name: url.lastPathComponent, path: canonicalPath, bookmark: bookmark)
            } else {
                try await database.saveSource(id: id, name: url.lastPathComponent, path: canonicalPath, bookmark: bookmark)
            }
            await reload()
            if let saved = try await database.findSource(path: canonicalPath) {
                stopMonitoring(id)
                await startMonitoring(saved)
                refresh(saved)
            }
        } catch { errorMessage = "无法保存文件夹授权。请重新选择可访问的普通文件夹。" }
    }

    func refreshAll() {
        if isPhotosList { Task { await refreshPhotos() }; return }
        for source in sources { refresh(source) }
    }

    func refreshPhotosAuthorization() async {
        photoLibrary.refreshAuthorization()
        guard let database else { return }
        do {
            try await database.setPhotosAccess(allowed: photoLibrary.canRead,
                message: photoLibrary.canRead ? nil : photoLibrary.authorizationMessage)
            if !photoLibrary.canRead { photoPreviewImage = nil }
        } catch { errorMessage = "无法保存照片访问状态，请重试。" }
    }

    func connectPhotos() async {
        if await photoLibrary.requestAccess() { await refreshPhotos() }
        else { await refreshPhotosAuthorization(); await reload() }
    }

    func refreshPhotos() async {
        guard let database else { return }
        await refreshPhotosAuthorization()
        guard photoLibrary.canRead else { await reload(); return }
        do {
            let photos = try await photoLibrary.fetchPhotos()
            try await database.savePhotos(photos)
            await reload()
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func setSensitivity(_ file: LibraryFile, state: String) async {
        guard let database else { return }
        do {
            try await database.setSensitivity(itemID: file.id, state: state)
            await reload()
        } catch { errorMessage = "未能保存隐私标记，请重试。" }
    }

    func refresh(_ source: FolderSource) {
        guard let database else { return }
        guard !source.needsAuthorization else {
            monitoringErrors[source.id] = "需要重新授权后才能刷新。"
            return
        }
        guard scanTasks[source.id] == nil else {
            refreshAfterScan.insert(source.id)
            return
        }
        let selectedBeforeScan = selectedFile
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
            if self.selectedFile?.sourceID == source.id, self.selectedFile != selectedBeforeScan {
                self.preparePreview(preferManaged: self.previewIsManaged)
            }
            if self.refreshAfterScan.remove(source.id) != nil,
               let current = self.folderWatchers[source.id] != nil ? source : self.sources.first(where: { $0.id == source.id }) {
                self.refresh(current)
            }
        }
    }

    func cancelScan(_ source: FolderSource) {
        sourceDebounces.removeValue(forKey: source.id)?.cancel()
        sourceChangeStartedAt[source.id] = nil
        refreshAfterScan.remove(source.id)
        scanTasks[source.id]?.cancel()
    }

    func remove(_ source: FolderSource) async {
        guard let database else { return }
        stopMonitoring(source.id)
        if let task = scanTasks[source.id] {
            task.cancel()
            await task.value
        }
        if selectedFile?.sourceID == source.id { releasePreview() }
        do {
            try await database.removeSource(source.id)
            if selectedSourceID == source.id { selectedSourceID = "all" }
            await reload()
        } catch {
            errorMessage = "移除来源失败，请重试。原文件未受影响。"
            await startMonitoring(source)
        }
    }

    func preparePreview(preferManaged: Bool = false) {
        releasePreview()
        originalError = nil
        managedError = nil
        previewError = nil
        guard let file = selectedFile else { return }
        guard !file.isPhoto else { return }
        if file.isImported {
            // Import grants access only for copying; subsequent reads use our own Vault.
        } else if file.isAvailable, let source = sources.first(where: { $0.id == file.sourceID }) {
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

    func releasePreview() {
        previewURL = nil
        originalURL = nil
        managedURL = nil
        previewIsManaged = false
        previewRoot?.stopAccessingSecurityScopedResource()
        previewRoot = nil
    }

    func quickLook(preferManaged: Bool = false) {
        if let file = selectedFile, file.isPhoto {
            guard let identifier = file.photoLocalIdentifier else { return }
            Task {
                do {
                    let image = try await photoLibrary.image(localIdentifier: identifier, large: true)
                    guard selectedFileID == file.id else { return }
                    photoPreviewImage = image
                    showPhotoPreview = true
                } catch { errorMessage = error.localizedDescription }
            }
            return
        }
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
        if selectedFile?.isPhoto == true { photoLibrary.openPhotosApp(); return }
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
        guard selectedFile?.isPhoto != true else { return }
        preparePreview()
        let target = selectedFile?.isImported == true ? managedURL : originalURL
        guard let target else { errorMessage = previewError ?? originalError; return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func requestImportedRemoval(_ file: LibraryFile) {
        guard let database, file.isImported, removingFileID == nil, pendingCopyRemoval == nil else { return }
        Task {
            do {
                _ = try await database.importedRemovalPath(itemID: file.id)
                filePendingRemoval = file
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func removeImportedFile(_ file: LibraryFile) async {
        guard let database, let managedStore, file.isImported, removingFileID == nil else { return }
        removingFileID = file.id
        defer { removingFileID = nil }
        if selectedFileID == file.id { showQuickLook = false; releasePreview() }
        do {
            try await managedStore.removeImportedFile(itemID: file.id, database: database)
            errorMessage = nil
        } catch let error as ImportedRemovalError {
            if case .copyCleanupPending(let path) = error { pendingCopyRemoval = path }
            errorMessage = error.localizedDescription
        } catch { errorMessage = "未能移除资料：" + error.localizedDescription }
        await reload()
        await reloadLinkedObjects()
    }

    func retryCopyRemoval() {
        guard let path = pendingCopyRemoval, let managedStore else { return }
        do {
            try managedStore.removeCopy(path)
            pendingCopyRemoval = nil
            errorMessage = nil
        } catch { errorMessage = ImportedRemovalError.copyCleanupPending(relativePath: path).localizedDescription }
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
        selectedSourceID = file.isPhoto ? PhotoLibraryController.sourceID : sources.contains(where: { $0.id == file.sourceID }) ? file.sourceID : "managed"
        search = file.name
        await reload()
        selectedFileID = file.id
    }

    func archiveSelected() async {
        guard let database, let store = managedStore, let file = selectedFile,
              !file.isPhoto, file.managedCopyPath == nil, archivingID == nil,
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

    func createOrder() {
        createMatter(kind: .order)
    }

    @discardableResult
    func createMatter(kind: MatterKind) -> Task<Void, Never> {
        errorMessage = nil
        // Capture this operation's context before the database query can suspend.
        let itemID = isFileList ? selectedFile?.id : nil
        let objectID = currentObjectID
        var draft = MatterDraft()
        draft.kind = kind.rawValue
        draft.itemIDs = itemID.map { [$0] } ?? []
        draft.objectID = objectID
        matterDraft = draft
        matterObjectSelectionMessage = nil
        return Task {
            do {
                var message: String?
                if objectID == nil, let itemID, let database {
                    let owners = try await database.objectsForItem(itemID)
                    if owners.count == 1 { draft.objectID = owners[0].id }
                    else if owners.count > 1 {
                        message = "此凭证关联了多个个人对象，请选择本事务的关联对象，也可保持不关联。"
                    }
                }
                guard matterDraft.id == draft.id else { return }
                matterDraft = draft
                matterObjectSelectionMessage = message
                showMatterEditor = true
            } catch {
                guard matterDraft.id == draft.id else { return }
                errorMessage = "读取凭证的对象关联失败，请重试。"
            }
        }
    }

    func editMatter(_ matter: MatterRecord) async {
        guard let database else { return }
        do {
            let facts = try await database.facts(matterID: matter.id)
            let files = try await database.files(FileQuery(matterID: matter.id, limit: Int.max)).files
            let actions = try await database.actions(matterID: matter.id)
            var draft = MatterDraft(id: matter.id, kind: matter.kind, title: matter.title,
                status: matter.status, objectID: matter.objectID, notes: matter.notes,
                itemIDs: files.map(\.id))
            draft.facts = facts.map {
                FactDraft(id: $0.id, key: $0.key, valueText: $0.valueText, valueType: $0.valueType,
                    state: $0.state, sourceItemID: $0.sourceItemID,
                    sourceExcerpt: $0.sourceExcerpt, origin: $0.origin)
            }
            draft.actions = actions.map(ActionDraft.init)
            matterDraft = draft
            matterObjectSelectionMessage = nil
            showMatterEditor = true
        } catch { errorMessage = "无法读取事务，请重试。" }
    }

    func showMatter(_ id: String, actionID: String? = nil) async {
        selectedActionID = actionID
        search = ""
        selectedFileID = nil
        selectedSourceID = "matters"
        selectedMatterID = id
        await loadMatterDetails()
    }

    private func openAction(_ id: String) async {
        guard let database else { return }
        do {
            guard let action = try await database.action(id: id) else {
                errorMessage = "此提醒对应的行动已不存在。"
                return
            }
            selectedActionID = id
            if let matterID = action.matterID { await showMatter(matterID, actionID: id) }
            else { selectedSourceID = "actions"; await reload() }
        } catch { errorMessage = "无法打开提醒对应的行动，请在待办中查看。" }
    }

    func loadMatterDetails() async {
        guard let database, let id = selectedMatterID else {
            matterFacts = []; matterFiles = []
            return
        }
        do {
            let facts = try await database.facts(matterID: id)
            let files = try await database.files(FileQuery(matterID: id, limit: Int.max)).files
            guard selectedMatterID == id, !Task.isCancelled else { return }
            matterFacts = facts
            matterFiles = files
        } catch {
            guard selectedMatterID == id, !Task.isCancelled else { return }
            errorMessage = "读取事务详情失败，请重试。"
        }
    }

    func saveMatter(_ draft: MatterDraft) async -> Bool {
        guard let database else { return false }
        do {
            let previous = try await database.actions(matterID: draft.id)
            for action in draft.actions {
                try validateReminder(action, previous: previous.first { $0.id == action.id })
            }
            let saved = try await database.saveMatter(draft)
            for action in saved {
                await updateReminder(action, previous: previous.first { $0.id == action.id })
            }
            if saved.isEmpty { reminderMessage = "事务已保存，已有行动与提醒保持不变。" }
            await reload()
            await showMatter(draft.id)
            await refreshReminderStatus(updateMessage: false)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存事务失败，请检查字段后重试。"
            return false
        }
    }

    private func validateReminder(_ draft: ActionDraft, previous: ActionRecord?) throws {
        guard !["done", "cancelled"].contains(draft.state), draft.dateConfirmed else { return }
        let changed = previous?.remindAt != draft.remindAt || previous?.dateConfirmed != true
            || previous?.state != "active"
        if changed, draft.remindAt.map({ $0 > Date() }) != true {
            throw ReminderEditError.futureTimeRequired
        }
    }

    private func updateReminder(_ saved: ActionRecord, previous: ActionRecord?) async {
        guard previous == nil || previous?.remindAt != saved.remindAt
                || previous?.dateConfirmed != saved.dateConfirmed || previous?.state != saved.state else {
            reminderMessage = "行动已保存，原提醒保持不变。"
            return
        }
        reminderMessage = await reminders.apply(actionID: saved.id, title: saved.title,
            remindAt: saved.remindAt, dateConfirmed: saved.dateConfirmed, state: saved.state).message
    }

    func saveAction(_ draft: ActionDraft, matterID: String) async -> Bool {
        guard let database else { return false }
        do {
            let previous = try await database.action(id: draft.id)
            try validateReminder(draft, previous: previous)
            let saved = try await database.saveAction(draft, matterID: matterID)
            await updateReminder(saved, previous: previous)
            selectedActionID = saved.id
            await reload()
            await refreshReminderStatus(updateMessage: false)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存行动失败，请重试。"
            return false
        }
    }

    func setActionState(_ action: ActionRecord, state: String) async {
        guard let database else { return }
        do {
            try await database.setActionState(id: action.id, state: state)
            if let saved = try await database.action(id: action.id) {
                reminderMessage = await reminders.apply(actionID: saved.id, title: saved.title,
                    remindAt: saved.remindAt, dateConfirmed: saved.dateConfirmed, state: saved.state).message
            }
            await reload()
            await refreshReminderStatus(updateMessage: false)
        } catch { errorMessage = "更新待办失败，请重试。" }
    }

    func canRescheduleReminder(_ action: ActionRecord, now: Date = Date()) -> Bool {
        action.state == "active" && action.dateConfirmed
            && action.remindAt.map { $0 > now } == true
            && !pendingActionIDs.contains(action.id)
    }

    func rescheduleReminder(actionID: String) async -> ReminderResult {
        guard let database else {
            return ReminderResult(scheduled: false, message: "资料库不可用，无法重新安排提醒。")
        }
        guard reschedulingActionIDs.insert(actionID).inserted else {
            return ReminderResult(scheduled: false, message: "正在核对这条提醒，请稍候。")
        }
        defer { reschedulingActionIDs.remove(actionID) }
        do {
            await refreshReminderStatus(updateMessage: false)
            guard let action = try await database.action(id: actionID), action.state == "active",
                  action.dateConfirmed, let time = action.remindAt, time > Date() else {
                let result = ReminderResult(scheduled: false, message: "仅可重新安排待处理、已确认未来时间的行动提醒。请先检查行动的状态和时间。")
                reminderMessage = result.message
                return result
            }
            if pendingActionIDs.contains(actionID) {
                let result = ReminderResult(scheduled: true, message: "系统已有这条待发送提醒，无需重复安排。")
                reminderMessage = result.message
                return result
            }
            let result = await reminders.apply(actionID: action.id, title: action.title,
                remindAt: action.remindAt, dateConfirmed: action.dateConfirmed, state: action.state)
            // A permission prompt can suspend this operation while the action is edited elsewhere.
            if let current = try await database.action(id: actionID),
               current.state != action.state || current.dateConfirmed != action.dateConfirmed
                    || current.remindAt != action.remindAt {
                await updateReminder(current, previous: action)
                await refreshReminderStatus(updateMessage: false)
                let updated = ReminderResult(scheduled: pendingActionIDs.contains(actionID),
                    message: "行动已更新，已按最新状态核对系统提醒。")
                reminderMessage = updated.message
                return updated
            }
            await refreshReminderStatus(updateMessage: false)
            let restored = pendingActionIDs.contains(actionID)
            let message = restored ? "系统提醒已重新安排，请查看实际待发送时间。"
                : result.scheduled ? "系统尚未返回这条待发送提醒，请稍后重试。" : result.message
            reminderMessage = message
            return ReminderResult(scheduled: restored, message: message)
        } catch {
            await refreshReminderStatus(updateMessage: false)
            let result = ReminderResult(scheduled: false, message: "无法读取行动或重新安排提醒，请稍后重试。")
            reminderMessage = result.message
            return result
        }
    }

    func refreshReminderStatus(updateMessage: Bool = true) async {
        async let pending = reminders.pendingReminders()
        async let delivered = reminders.deliveredActionIDs()
        let (requests, received) = await (pending, delivered)
        pendingActionIDs = Set(requests.keys)
        pendingReminderDates = requests
        deliveredActionIDs = received
        if updateMessage { reminderMessage = await reminders.permissionMessage() }
    }

    func extractText(from file: LibraryFile) async throws -> DocumentTextResult {
        try await requireOrdinaryDocument(file)
        var root: URL?
        var documentURL: URL?
        if file.isAvailable, let source = sources.first(where: { $0.id == file.sourceID }) {
            do {
                let access = try FolderAccess.resolve(source)
                root = access.url
                documentURL = try FolderAccess.fileURL(relativePath: file.relativePath, root: access.url)
            } catch {
                root?.stopAccessingSecurityScopedResource()
                root = nil
            }
        }
        if documentURL == nil, let relative = file.managedCopyPath, let managedStore {
            documentURL = try managedStore.url(for: relative)
        }
        guard let documentURL else { throw AccessError.missing }
        let scopedRoot = root
        let worker = Task.detached(priority: .userInitiated) {
            defer { scopedRoot?.stopAccessingSecurityScopedResource() }
            return try DocumentTextExtractor.extract(from: documentURL, allowSensitiveName: true)
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try await requireOrdinaryDocument(file)
        return result
    }

    private func requireOrdinaryDocument(_ file: LibraryFile) async throws {
        guard let database, let current = try await database.file(id: file.id),
              !current.isPhoto, current.sensitivity == "normal" else { throw DocumentReadError.sensitive }
    }

    func suggestFacts(file: LibraryFile, text: String, allowedKeys: [String]) async throws -> [DocumentFactSuggestion] {
        try await requireOrdinaryDocument(file)
        let result = try await LocalFactAssistant.suggest(text: text, fileName: file.name,
            allowedKeys: allowedKeys, allowSensitiveName: true)
        try await requireOrdinaryDocument(file)
        return result
    }

    func saveDocumentText(file: LibraryFile, text: String) async -> Bool {
        guard let database else { return false }
        do {
            try await database.saveDocumentText(itemID: file.id, text: text, expectedFile: file)
            await reload()
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存正文索引失败，请重试。"
            return false
        }
    }

    func indexSelectedDocument() async {
        guard let file = selectedFile, indexingID == nil else { return }
        indexingID = file.id
        errorMessage = nil
        defer { indexingID = nil }
        do {
            let result = try await extractText(from: file)
            _ = await saveDocumentText(file: file, text: result.text)
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func removeDocumentText(_ file: LibraryFile) async {
        guard let database else { return }
        do {
            try await database.deleteDocumentText(itemID: file.id)
            await reload()
        } catch { errorMessage = "移除正文索引失败，请重试。" }
    }

    func exportBackup() {
        guard !backupBusy, let database, let managedStore else { return }
        let panel = NSSavePanel()
        panel.title = "导出 PersonalSpace 备份"
        panel.message = "备份包含明文资料库和托管副本，请选择你信任的位置。原来源文件和系统照片不会被复制。"
        panel.nameFieldStringValue = "PersonalSpace-" + Date().formatted(.iso8601.year().month().day()) + ".personalspacebackup"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        backupBusy = true
        backupMessage = "正在建立一致性快照、复制托管凭证并校验…"
        Task {
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() }; backupBusy = false }
            do {
                let manifest = try await LibraryBackup.export(database: database, vaultRoot: managedStore.root, to: destination)
                backupMessage = "备份已导出并校验：\(manifest.files.count) 个文件。\n" + destination.path
            } catch { backupMessage = "备份未完成：" + error.localizedDescription }
        }
    }

    var canSwitchLibraries: Bool { librarySelection != nil && libraryLocation != nil }
    var originalLibrary: LibraryLocation? { try? librarySelection?.location("original") }

    func refreshLibrarySelection() {
        guard let librarySelection, let libraryLocation else { return }
        do {
            let choice = try librarySelection.selection()
            pendingLibrary = choice.active == libraryLocation.id ? nil : try librarySelection.location(choice.active)
            retainedLibrary = try choice.previous.map { try librarySelection.location($0) }
        } catch { backupMessage = "无法读取资料库切换记录：" + error.localizedDescription }
    }

    func chooseBackupToActivate() {
        guard !backupBusy, canSwitchLibraries else { return }
        let panel = NSOpenPanel()
        panel.title = "恢复并启用 PersonalSpace 备份"
        panel.message = "先校验并核对备份内容，再恢复为下次启动使用的资料库。当前资料库不会被覆盖。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupBusy = true
        backupMessage = "正在校验备份内容…"
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; backupBusy = false }
            do {
                let bookmark = try FolderAccess.bookmark(for: url)
                let summary = try await LibraryBackup.inspect(at: url)
                backupCandidate = BackupCandidate(url: url, bookmark: bookmark, summary: summary)
                backupMessage = "备份校验通过，请核对后确认恢复。"
            } catch { backupMessage = "备份校验失败，未切换资料库：" + error.localizedDescription }
        }
    }

    func activateBackup(_ candidate: BackupCandidate) {
        guard !backupBusy, let librarySelection, let libraryLocation else { return }
        backupCandidate = nil
        backupBusy = true
        backupMessage = "正在恢复到新目录并验证资料库与托管凭证…"
        Task {
            defer { backupBusy = false }
            var ownedDirectory: URL?
            do {
                let source = FolderSource(id: "backup", name: "备份", path: candidate.url.path,
                    bookmark: candidate.bookmark, lastScannedAt: nil, lastError: nil, fileCount: 0)
                let access = try FolderAccess.resolve(source)
                defer { access.url.stopAccessingSecurityScopedResource() }
                let destination = try librarySelection.newRestoreLocation()
                let copied = try await LibraryBackup.restore(from: access.url, to: destination.root)
                ownedDirectory = destination.root
                guard copied == candidate.summary.manifest else { throw ActiveLibraryError.backupChanged }
                let restored = try LibraryDatabase(path: destination.databaseURL.path)
                do {
                    try await restored.prepareRestoredLibrary()
                    try restored.queue.close()
                } catch { try? restored.queue.close(); throw error }
                try JSONEncoder().encode(RestoredLibraryOrigin(name: candidate.url.lastPathComponent,
                    date: candidate.summary.manifest.createdAt)).write(to: destination.root.appendingPathComponent("origin.json"), options: .atomic)
                try await Task.detached(priority: .utility) {
                    try librarySelection.scheduleSwitch(to: destination, from: libraryLocation)
                }.value
                ownedDirectory = nil // The atomic pointer now owns this fully validated directory.
                refreshLibrarySelection()
                backupMessage = "恢复与验证完成。下次启动将启用此备份；当前资料库与原件保持不变。外部来源需重新授权，提醒需重新确认。"
            } catch {
                if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
                backupMessage = "恢复未启用，当前资料库保持原状：" + error.localizedDescription
            }
        }
    }

    func switchLibraryAfterRestart(to target: LibraryLocation) {
        guard !backupBusy, let librarySelection, let libraryLocation else { return }
        backupBusy = true
        backupMessage = "正在验证要切回的资料库…"
        Task {
            defer { backupBusy = false }
            do {
                try await Task.detached(priority: .utility) {
                    try librarySelection.scheduleSwitch(to: target, from: libraryLocation)
                }.value
                refreshLibrarySelection()
                backupMessage = pendingLibrary == nil ? "已取消下次启动切换，继续使用当前资料库。" : "已验证并记录切换。请退出并重新打开应用；当前与保留资料库均未覆盖。"
            } catch { backupMessage = "未切换资料库：" + error.localizedDescription }
        }
    }

    func previewRetainedLibrary(_ location: LibraryLocation) {
        guard !backupBusy else { return }
        backupBusy = true
        Task {
            defer { backupBusy = false }
            do {
                let saved = try LibraryDatabase(path: location.databaseURL.path)
                defer { try? saved.queue.close() }
                let copies = try await saved.files(FileQuery(managedOnly: true, limit: Int.max)).files
                restoredLibrary = RestoredLibrary(root: location.root, files: copies, title: location.title)
            } catch { backupMessage = "无法查看保留资料库：" + error.localizedDescription }
        }
    }

    func restoreBackup() {
        guard !backupBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "验证并查看 PersonalSpace 备份"
        panel.message = "直接校验原备份，不创建恢复资料库。需要预览时才建立可清理的临时副本。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        backupBusy = true
        verifiedBackup = nil
        backupMessage = "正在校验备份内容与完整性…"
        Task {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() }; backupBusy = false }
            do {
                let bookmark = try FolderAccess.bookmark(for: source)
                let summary = try await LibraryBackup.inspect(at: source)
                verifiedBackup = BackupCandidate(url: source, bookmark: bookmark, summary: summary)
                backupMessage = "备份验证通过，未创建永久副本。可预览托管凭证，或确认后恢复并启用。"
            } catch { backupMessage = "备份验证未通过：" + error.localizedDescription }
        }
    }

    func previewVerifiedBackup(_ candidate: BackupCandidate) {
        guard !backupBusy else { return }
        finishBackupPreview()
        backupBusy = true
        backupMessage = "正在准备临时预览副本…"
        Task {
            defer { backupBusy = false }
            do {
                let source = FolderSource(id: "backup", name: "备份", path: candidate.url.path,
                    bookmark: candidate.bookmark, lastScannedAt: nil, lastError: nil, fileCount: 0)
                let access = try FolderAccess.resolve(source)
                defer { access.url.stopAccessingSecurityScopedResource() }
                let destination = try await LibraryBackup.makePreview(from: access.url)
                backupPreviewDirectory = destination
                let restored = try LibraryDatabase(path: destination.appendingPathComponent("library.sqlite").path)
                defer { try? restored.queue.close() }
                let copies = try await restored.files(FileQuery(managedOnly: true, limit: Int.max)).files
                restoredLibrary = RestoredLibrary(root: destination, files: copies, title: "备份临时预览", temporary: true)
                backupMessage = "临时预览已准备好，关闭预览后清理；正式资料库保持不变。"
            } catch {
                finishBackupPreview()
                backupMessage = "无法预览备份：" + error.localizedDescription
            }
        }
    }

    func finishBackupPreview() {
        guard let directory = backupPreviewDirectory else { return }
        do {
            try LibraryBackup.removePreview(at: directory)
            backupPreviewDirectory = nil
            if restoredLibrary?.temporary == true { restoredLibrary = nil }
            backupMessage = "临时预览副本已清理，原备份与正式资料库保持不变。"
        } catch { backupMessage = "临时预览副本未能清理：" + error.localizedDescription }
    }

}

private enum DocumentReadError: LocalizedError {
    case sensitive
    var errorDescription: String? {
        "照片或已标记敏感的资料不读取正文、不交给模型处理。可手动填写必要字段；普通文件的隐私标记可在详情中调整。"
    }
}

private enum ReminderEditError: LocalizedError {
    case futureTimeRequired
    var errorDescription: String? { "请为已确认的提醒选择一个未来时间。" }
}
