import AppKit
import Foundation
import UniformTypeIdentifiers

extension LibraryModel {
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
        lastImportedIDs = []
        importMessage = nil
        selectedSourceID = "inbox"
        selectedFileID = nil
        search = ""
        importTask = Task {
            defer {
                scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                importingTotal = 0
            }
            var importedIDs: [String] = []
            for url in urls {
                do {
                    let id = try await store.importFile(sourceURL: url, database: database)
                    importedIDs.append(id)
                    lastImportedIDs.append(id)
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

    func waitForImport() async { await importTask?.value }

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

}
