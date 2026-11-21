import AppKit
import Foundation
import GRDB

extension LibraryModel {
    func startMonitoring(_ source: FolderSource) async {
        guard !source.autoUpdatePaused, folderWatchers[source.id] == nil else { return }
        do {
            let access = try FolderAccess.resolve(source)
            do {
                let watcher = try FolderWatcher(root: access.url, exclusions: scanExclusions) { [weak self] paths in
                    self?.sourceChanged(source, paths: paths)
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
        changedSourcePaths[id] = nil
        if let watch = folderWatchers.removeValue(forKey: id) {
            watch.watcher.stop()
            watch.root.stopAccessingSecurityScopedResource()
        }
        monitoredSourceIDs.remove(id)
        monitoringErrors[id] = nil
    }

    private func sourceChanged(_ source: FolderSource, paths: [String]?) {
        let id = source.id
        guard folderWatchers[id] != nil else { return }
        if let paths { changedSourcePaths[id, default: []].formUnion(paths) }
        else { refreshAfterScan.insert(id) }
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
            self.flushSourceChanges(source)
        }
    }

    private func flushSourceChanges(_ source: FolderSource) {
        guard scanTasks[source.id] == nil else { return }
        if refreshAfterScan.remove(source.id) != nil {
            changedSourcePaths[source.id] = nil
            refresh(source)
        } else if let paths = changedSourcePaths.removeValue(forKey: source.id), !paths.isEmpty {
            // When a directory changed, one subtree walk also covers its child events.
            let sorted = paths.sorted()
            var scopes: [String] = []
            for path in sorted where !scopes.contains(where: { path.hasPrefix($0 + "/") }) { scopes.append(path) }
            scan(source, changedPaths: scopes)
        }
    }


    @discardableResult
    func addFolders(replacing source: FolderSource? = nil, fromAssistant: Bool = false) -> Task<Bool, Never>? {
        guard database != nil else { return nil }
        guard countingFolderName == nil else {
            errorMessage = "正在统计文件数量，请先完成或取消当前统计。"
            return nil
        }
        let panel = NSOpenPanel()
        panel.title = source == nil ? "添加资料来源" : "重新授权来源"
        panel.message = source == nil ? "先轻量统计文件数量，核对后再建立索引。原文件保留在原位置。" :
            (source?.needsAuthorization == true ? "请选择与此来源对应的文件夹；新电脑上的路径可以不同，将保留原资料关联。" : "请重新选择原来的文件夹，恢复访问权限。")
        panel.prompt = source == nil ? "统计文件" : "重新授权"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = source == nil
        panel.canCreateDirectories = false
        if fromAssistant, let owner = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }) {
            // A sheet on the library leaves the separate assistant window usable.
            return Task {
                let response = await withCheckedContinuation { continuation in
                    panel.beginSheetModal(for: owner) { continuation.resume(returning: $0) }
                }
                guard response == .OK else { return false }
                var saved = false
                for url in panel.urls {
                    guard await saveFolder(url, replacing: source) else { return saved }
                    saved = true
                }
                return saved
            }
        }
        guard panel.runModal() == .OK else { return nil }
        let urls = panel.urls
        return Task {
            var saved = false
            for url in urls {
                guard await saveFolder(url, replacing: source) else { return saved }
                saved = true
            }
            return saved
        }
    }

    /// Counts an already-authorized location; no source or item is saved here.
    func countFolder(_ url: URL) async throws -> FolderScanReport {
        guard folderCountTask == nil else { throw AccessError.countInProgress }
        let token = UUID()
        folderCountToken = token
        countingFolderName = url.lastPathComponent
        countedFiles = 0
        let exclusions = scanExclusions
        let worker = Task.detached(priority: .utility) { [weak self] in
            try FolderScanner.count(root: url, exclusions: exclusions) { [weak self] count in
                Task { @MainActor [weak self] in
                    guard self?.folderCountToken == token else { return }
                    self?.countedFiles = count
                }
            }
        }
        folderCountTask = worker
        defer {
            folderCountTask = nil
            folderCountToken = nil
            countingFolderName = nil
        }
        return try await withTaskCancellationHandler {
            let report = try await worker.value
            try Task.checkCancellation()
            return report
        } onCancel: { worker.cancel() }
    }

    func cancelFolderCount() { folderCountTask?.cancel() }


    func waitForScans(_ ids: [String]) async {
        for id in ids { await scanTasks[id]?.value }
    }

    private func saveFolder(_ url: URL, replacing source: FolderSource?) async -> Bool {
        guard let database else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey])
            guard values.isPackage != true, values.isSymbolicLink != true else { throw AccessError.authorization }
            let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            if let source, !source.needsAuthorization,
               canonicalPath != URL(fileURLWithPath: source.path).resolvingSymlinksInPath().path {
                errorMessage = "请重新选择原来源文件夹。添加其它位置请使用「添加文件夹」。"
                return false
            }
            let existing: FolderSource?
            if let source { existing = source }
            else { existing = try await database.findSource(path: canonicalPath) }
            let id = existing?.id ?? UUID().uuidString
            guard scanning[id] == nil else { return false }
            let report = try await countFolder(url)
            try Task.checkCancellation()
            let alert = NSAlert()
            alert.messageText = "「\(url.lastPathComponent)」统计完成"
            alert.informativeText = "可读取范围内共有 \(report.fileCount.formatted()) 个文件。\n"
                + (report.fileCount >= 100_000 ? "提示：文件数量较大，首次建库和启动补扫会耗时较长，建议改选存放资料的具体子文件夹。\n" : "")
                + (report.issues.isEmpty ? "" : "\(report.issues.count.formatted()) 个位置未能完整读取，未读取的内容不计入总数。\n")
                + "已跳过隐藏文件、目录包和符号链接；尚未建立索引。\n是否继续建立索引？文件夹之后有变化时，实际入库数量可能不同。"
            alert.addButton(withTitle: "建立索引")
            alert.addButton(withTitle: "暂不添加")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            try Task.checkCancellation()
            let bookmark = try FolderAccess.bookmark(for: url)
            if source != nil {
                try await database.reauthorizeSource(id: id, name: url.lastPathComponent, path: canonicalPath, bookmark: bookmark)
            } else {
                try await database.saveSource(id: id, name: url.lastPathComponent, path: canonicalPath, bookmark: bookmark)
            }
            try database.setSourceAutoUpdatePaused(id, paused: false)
            await reload()
            if let saved = try await database.findSource(path: canonicalPath) {
                stopMonitoring(id)
                await startMonitoring(saved)
                refresh(saved)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = (error as? AccessError)?.errorDescription ?? "统计或保存文件夹失败。请检查访问权限后重试。"
            return false
        }
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
        changedSourcePaths[source.id] = nil
        scan(source, changedPaths: nil)
    }

    private func scan(_ source: FolderSource, changedPaths: [String]?) {
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
        let token = UUID()
        scanTokens[source.id] = token
        scanning[source.id] = 0
        if changedPaths != nil { updatingSourceIDs.insert(source.id) }
        scanListReloads[source.id] = .now
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
                let exclusions = self.scanExclusions
                let worker = Task.detached(priority: .utility) { [weak self] in
                    defer { access.url.stopAccessingSecurityScopedResource() }
                    var total = 0
                    let scopes: [String?] = changedPaths?.map(Optional.some) ?? [nil]
                    for scope in scopes {
                        try Task.checkCancellation()
                        let offset = total
                        let report = try FolderScanner.scan(root: access.url, sourceID: source.id, database: database,
                                               exclusions: exclusions, scope: scope) { [weak self] count in
                            Task { @MainActor [weak self] in
                                guard let self, self.scanTokens[source.id] == token else { return }
                                self.scanning[source.id] = offset + count
                                let now = ContinuousClock.now
                                if self.reloadTask == nil,
                                   self.scanListReloads[source.id].map({ $0.duration(to: now) >= .seconds(1) }) ?? true {
                                    self.scanListReloads[source.id] = now
                                    await self.reload()
                                }
                            }
                        }
                        total += report.fileCount
                    }
                }
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
            } catch is CancellationError {
                // A partial scan never invalidates previously indexed files.
            } catch {
                // Do not repeatedly retry a large, partially unreadable source on every event.
                self.pauseAutomaticUpdates(source)
                let nsError = error as NSError
                var message = (error as? AccessError)?.errorDescription ?? "扫描中断，已有资料保留。"
                var diagnostic: [String: String] = ["domain": nsError.domain, "code": String(nsError.code)]
                if let sqliteError = error as? DatabaseError {
                    message = "资料库写入失败，扫描未完成。"
                    diagnostic["reason"] = sqliteError.message
                    diagnostic["sqlite_code"] = String(sqliteError.extendedResultCode.rawValue)
                }
                if let base = self.librarySelection?.base {
                    let directory = base.appendingPathComponent("Diagnostics")
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(diagnostic) {
                        try? data.write(to: directory.appendingPathComponent("last-scan-failure.json"), options: .atomic)
                    }
                }
                do {
                    try await database.setSourceError(source.id, message: message)
                } catch { self.errorMessage = "扫描状态保存失败，请重试。" }
            }
            self.scanning[source.id] = nil
            self.scanTokens[source.id] = nil
            self.updatingSourceIDs.remove(source.id)
            self.scanListReloads[source.id] = nil
            self.scanTasks[source.id] = nil
            await self.reload()
            if self.selectedFile?.sourceID == source.id, self.selectedFile != selectedBeforeScan {
                self.preparePreview(preferManaged: self.previewIsManaged)
            }
            if let current = self.sources.first(where: { $0.id == source.id }), self.folderWatchers[source.id] != nil {
                self.flushSourceChanges(current)
            }
        }
    }

    func cancelScan(_ source: FolderSource) {
        scanTasks[source.id]?.cancel()
        pauseAutomaticUpdates(source)
    }

    private func pauseAutomaticUpdates(_ source: FolderSource) {
        stopMonitoring(source.id)
        do {
            try database?.setSourceAutoUpdatePaused(source.id, paused: true)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].autoUpdatePaused = true
            }
        } catch { errorMessage = "已停止扫描，但暂停状态未保存；重开应用可能恢复自动更新。" }
    }

    func resumeAutomaticUpdates(_ source: FolderSource) async {
        guard let database, !source.needsAuthorization, scanTasks[source.id] == nil else { return }
        do {
            try database.setSourceAutoUpdatePaused(source.id, paused: false)
            await reload()
            guard let current = sources.first(where: { $0.id == source.id }) else { return }
            await startMonitoring(current)
            refresh(current)
        } catch { errorMessage = "未能恢复自动更新，请重试。" }
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

}
