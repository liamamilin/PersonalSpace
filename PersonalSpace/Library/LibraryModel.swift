import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryModel: ObservableObject {
    @Published var matters: [MatterRecord] = []
    @Published var actions: [ActionRecord] = []
    @Published var selectedMatterID: String?
    @Published var selectedActionID: String?
    @Published var matterFacts: [FactRecord] = []
    @Published var matterFiles: [LibraryFile] = []
    @Published var pendingActionIDs: Set<String> = []
    @Published var deliveredActionIDs: Set<String> = []
    @Published var reminderMessage: String?
    @Published var showMatterEditor = false
    @Published var matterDraft = MatterDraft()
    let reminders = ReminderController()
    let photoLibrary = PhotoLibraryController()
    @Published var photoPreviewImage: NSImage?
    @Published var showPhotoPreview = false
    @Published var backupBusy = false
    @Published var backupMessage: String?
    @Published var restoredLibrary: RestoredLibrary?
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
    var isScanning: Bool { !scanning.isEmpty }

    init(database suppliedDatabase: LibraryDatabase? = nil) {
        do {
            if let suppliedDatabase { database = suppliedDatabase }
            else { database = try LibraryDatabase.applicationDatabase() }
        }
        catch {
            database = nil
            storageUnavailable = true
            errorMessage = "无法打开本地资料库。请检查磁盘空间和应用数据目录的访问权限后重新启动。"
        }
        do { managedStore = try ManagedFileStore.applicationStore() }
        catch { errorMessage = "托管目录无法访问，文件搜索仍可使用。" }
        reminders.onOpenAction = { [weak self] id in
            guard let self else { return }
            self.openLibraryWindow?()
            NSApp.activate(ignoringOtherApps: true)
            Task { await self.openAction(id) }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        await refreshPhotosAuthorization()
        await reload()
        await refreshReminderStatus()
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

    private func releasePreview() {
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

    func createMatter(kind: MatterKind) {
        errorMessage = nil
        matterDraft = MatterDraft()
        matterDraft.kind = kind.rawValue
        if let file = selectedFile, isFileList { matterDraft.itemIDs = [file.id] }
        if let objectID = currentObjectID { matterDraft.objectID = objectID }
        showMatterEditor = true
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
            if let action = actions.first {
                draft.action = ActionDraft(id: action.id, title: action.title, dueDate: action.dueDate,
                    remindAt: action.remindAt, state: action.state, dateConfirmed: action.dateConfirmed)
            }
            matterDraft = draft
            showMatterEditor = true
        } catch { errorMessage = "无法读取事务，请重试。" }
    }

    func showMatter(_ id: String) async {
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
            if let matterID = action.matterID { await showMatter(matterID) }
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
        if let action = draft.action, action.dateConfirmed,
           !["done", "cancelled"].contains(action.state),
           action.remindAt.map({ $0 <= Date() }) != false {
            errorMessage = "请为已确认的提醒选择一个未来时间。"
            return false
        }
        do {
            let previous = try await database.actions(matterID: draft.id)
            let saved = try await database.saveMatter(draft)
            // Only a successful database save may replace or cancel a system request.
            for action in previous where action.id != saved?.id {
                _ = await reminders.apply(actionID: action.id, title: action.title,
                    remindAt: nil, dateConfirmed: false, state: "cancelled")
            }
            if let saved {
                reminderMessage = await reminders.apply(actionID: saved.id, title: saved.title,
                    remindAt: saved.remindAt, dateConfirmed: saved.dateConfirmed, state: saved.state).message
            } else { reminderMessage = previous.isEmpty ? "事务已保存。" : "事务已保存，原系统提醒已取消。" }
            await reload()
            await showMatter(draft.id)
            await refreshReminderStatus(updateMessage: false)
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "保存事务失败，请检查字段后重试。"
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

    func refreshReminderStatus(updateMessage: Bool = true) async {
        async let pending = reminders.pendingActionIDs()
        async let delivered = reminders.deliveredActionIDs()
        (pendingActionIDs, deliveredActionIDs) = await (pending, delivered)
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
            try await database.saveDocumentText(itemID: file.id, text: text)
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

    func restoreBackup() {
        guard !backupBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 PersonalSpace 备份"
        panel.message = "先完整校验，再恢复到应用内的全新独立测试库。当前资料库不会被替换。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        backupBusy = true
        backupMessage = "正在校验备份并恢复到全新测试资料库…"
        Task {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() }; backupBusy = false }
            do {
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                let parent = support.appendingPathComponent("PersonalSpace/RestoredLibraries", isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let destination = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
                _ = try await LibraryBackup.restore(from: source, to: destination)
                let restored = try LibraryDatabase(path: destination.appendingPathComponent("library.sqlite").path)
                let copies = try await restored.files(FileQuery(managedOnly: true, limit: Int.max)).files
                restoredLibrary = RestoredLibrary(root: destination, files: copies)
                backupMessage = "备份校验与独立恢复完成：\(copies.count) 份托管凭证可供检查。当前资料库未替换，提醒未重新安排。"
            } catch { backupMessage = "恢复未完成，当前资料库保持原状：" + error.localizedDescription }
        }
    }
}

private enum DocumentReadError: LocalizedError {
    case sensitive
    var errorDescription: String? {
        "照片或已标记敏感的资料不读取正文、不交给模型处理。可手动填写必要字段；普通文件的隐私标记可在详情中调整。"
    }
}
