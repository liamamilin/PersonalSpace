import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GRDB

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
    @Published var reschedulingActionIDs: Set<String> = []
    @Published var pendingReminderDates: [String: Date] = [:]
    @Published var deliveredActionIDs: Set<String> = []
    @Published var reminderMessage: String?
    @Published var showMatterEditor = false
    @Published var matterDraft = MatterDraft()
    @Published var matterObjectSelectionMessage: String?
    @Published var assistantActionRequest: AssistantActionRequest?
    @Published var settingsSection = "sources"
    let reminders: ReminderController
    let photoLibrary = PhotoLibraryController()
    @Published var photoPreviewImage: NSImage?
    @Published var showPhotoPreview = false
    @Published var backupBusy = false
    @Published var backupMessage: String?
    @Published var restoredLibrary: RestoredLibrary?
    @Published var backupCandidate: BackupCandidate?
    @Published var verifiedBackup: BackupCandidate?
    var backupPreviewDirectory: URL?
    @Published var pendingLibrary: LibraryLocation?
    @Published var retainedLibrary: LibraryLocation?
    private(set) var libraryLocation: LibraryLocation?
    var librarySelection: ActiveLibrary?
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
    @Published private(set) var finishedQuery: FileQuery?
    @Published private(set) var queryLoadError: String?
    @Published var search = ""
    @Published var searchBody = false
    @Published var indexingID: String?
    @Published var selectedSourceID = "all"
    @Published var selectedFileID: String?
    @Published var sort: FileSort = .name
    @Published var ascending = true
    @Published var limit = 500
    @Published var scanning: [String: Int] = [:]
    @Published var countingFolderName: String?
    @Published var countedFiles = 0
    var folderCountTask: Task<FolderScanReport, Error>?
    var folderCountToken: UUID?
    @Published var updatingSourceIDs: Set<String> = []
    @Published var monitoredSourceIDs: Set<String> = []
    @Published var monitoringErrors: [String: String] = [:]
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
    var lastImportedIDs: [String] = []
    @Published var importFailures: [String] = []
    @Published var filePendingRemoval: LibraryFile?
    @Published var removingFileID: String?
    @Published var pendingCopyRemoval: String?
    @Published var loadingDrop = false
    let database: LibraryDatabase?
    var assistantDatabase: LibraryDatabase? { database }
    var importTask: Task<Void, Never>?
    var backupTask: Task<Void, Never>?
    var scanTasks: [String: Task<Void, Never>] = [:]
    var folderWatchers: [String: (watcher: FolderWatcher, root: URL)] = [:]
    var sourceDebounces: [String: Task<Void, Never>] = [:]
    var sourceChangeStartedAt: [String: ContinuousClock.Instant] = [:]
    var refreshAfterScan: Set<String> = []
    var changedSourcePaths: [String: Set<String>] = [:]
    var scanListReloads: [String: ContinuousClock.Instant] = [:]
    var scanTokens: [String: UUID] = [:]
    private var started = false
    var managedStore: ManagedFileStore?
    private var previewRoot: URL?
    var reloadTask: Task<Void, Never>?
    private var requestedReload = 0
    private var completedReload = 0
    private var needsFullReload = true
    var scanExclusions: FolderScanExclusions {
        FolderScanExclusions(databasePath: database?.queue.path,
            directories: librarySelection.map { [$0.base] } ?? [])
    }

    var selectedFile: LibraryFile? { files.first { $0.id == selectedFileID } }
    var isQueryLoading: Bool { !storageUnavailable && finishedQuery != query }
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
                guard !source.autoUpdatePaused else { continue }
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
        folderCountTask?.cancel()
    }


    func reload(filesOnly: Bool = false) async {
        guard database != nil, !Task.isCancelled else { return }
        if !filesOnly { needsFullReload = true }
        requestedReload += 1
        let revision = requestedReload
        // Callers wait for a read begun after their request. Concurrent callers
        // share the current read and a follow-up instead of invalidating it.
        while completedReload < revision, !Task.isCancelled {
            if let reloadTask {
                await reloadTask.value
            } else {
                let target = requestedReload
                let request = query
                let full = needsFullReload || finishedQuery == nil
                needsFullReload = false
                let task = Task { [self] in
                    await readLibrary(request, full: full)
                    completedReload = target
                    reloadTask = nil
                }
                reloadTask = task
                await task.value
            }
        }
    }

    private func readLibrary(_ request: FileQuery, full: Bool) async {
        guard let database else { return }
        do {
            let metadata: (sources: [FolderSource], objects: [PersonalObject], matters: [MatterRecord], actions: [ActionRecord])?
            if full {
                let newSources = try await database.sources()
                let newObjects = try await database.objects()
                let newMatters = try await database.matters()
                let newActions = try await database.actions()
                metadata = (newSources, newObjects, newMatters, newActions)
            } else {
                metadata = nil
            }
            let result = try await database.files(request)
            let pendingCount = full ? try await database.files(FileQuery(inboxOnly: true, limit: 0)).total : nil
            guard request == query else { return }
            if let metadata {
                sources = metadata.sources
                objects = metadata.objects
                matters = metadata.matters
                actions = metadata.actions
            }
            if let pendingCount { inboxCount = pendingCount }
            files = result.files
            total = result.total
            queryLoadError = nil
            finishedQuery = request
            if let id = selectedFileID, !files.contains(where: { $0.id == id }) {
                selectedFileID = nil
            }
            if full, selectedMatterID != nil { await loadMatterDetails() }
        } catch {
            guard request == query else { return }
            queryLoadError = "读取资料库失败，请重试。"
            finishedQuery = request
            errorMessage = queryLoadError
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

}
