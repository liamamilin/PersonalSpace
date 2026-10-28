import Foundation
import UniformTypeIdentifiers

struct FolderScanner {
    static func scan(root: URL, sourceID: String, database: LibraryDatabase,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isPackageKey, .nameKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentTypeKey]
        let manager = FileManager.default
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isPackage != true,
              rootValues.isSymbolicLink != true else { throw AccessError.scan }
        // A missing/offline source must not look like a successful empty scan.
        _ = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var enumerationFailed = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants, .skipsHiddenFiles], errorHandler: { _, _ in
                enumerationFailed = true
                return true
            }) else { throw AccessError.scan }
        let scanID = UUID().uuidString
        let prefix = root.standardizedFileURL.path + "/"
        var batch: [ScannedFile] = []
        var count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true || values.isPackage == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                // Validate parent components too: do not index through a substituted symlink.
                _ = try FolderAccess.fileURL(relativePath: relative, root: root)
                batch.append(ScannedFile(relativePath: relative, name: values.name ?? url.lastPathComponent,
                    typeIdentifier: values.contentType?.identifier ?? UTType.data.identifier,
                    bytes: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                    createdAt: values.creationDate))
                count += 1
                if batch.count >= 100 {
                    try database.saveBatch(batch, sourceID: sourceID, scanID: scanID)
                    batch.removeAll(keepingCapacity: true)
                    progress(count)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { enumerationFailed = true }
        }
        try Task.checkCancellation()
        if !batch.isEmpty {
            try database.saveBatch(batch, sourceID: sourceID, scanID: scanID)
            progress(count)
        }
        guard !enumerationFailed else { throw AccessError.scan }
        try database.finishScan(sourceID: sourceID, scanID: scanID)
        progress(count)
    }
}
