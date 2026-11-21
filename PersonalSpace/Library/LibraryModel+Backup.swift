import AppKit
import Foundation

extension LibraryModel {
    func waitForBackup() async { await backupTask?.value }

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
        backupTask = Task {
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
        backupTask = Task {
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
        backupTask = Task {
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
        backupTask = Task {
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
        backupTask = Task {
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
        backupTask = Task {
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
        backupTask = Task {
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
