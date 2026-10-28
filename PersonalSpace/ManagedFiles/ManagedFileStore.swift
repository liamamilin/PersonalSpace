import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ManagedCopy: Sendable {
    let relativePath: String
    let sha256: String
}

struct ManagedFileStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    static func applicationStore() throws -> ManagedFileStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return ManagedFileStore(root: support.appendingPathComponent("PersonalSpace", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true))
    }

    // The caller holds the source folder's security-scoped access for this operation.
    func copy(sourceURL: URL) throws -> ManagedCopy {
        guard sourceURL.isFileURL else { throw ManagedFileError.invalidSource }
        let source = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey])
        guard source.isRegularFile == true, source.isSymbolicLink != true, source.isPackage != true else {
            throw ManagedFileError.invalidSource
        }
        try prepareRoot()
        try Task.checkCancellation()

        let identifier = UUID().uuidString
        let directory = root.appendingPathComponent(identifier, isDirectory: true)
        let filename = sourceURL.lastPathComponent
        let relativePath = identifier + "/" + filename
        guard Self.isValidRelativePath(relativePath) else { throw ManagedFileError.invalidPath }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        var committed = false
        defer {
            // Only the unique directory created by this call can be removed on failure.
            if !committed { try? manager.removeItem(at: directory) }
        }

        let temporary = directory.appendingPathComponent(".partial-" + UUID().uuidString)
        let destination = directory.appendingPathComponent(filename)
        try manager.copyItem(at: sourceURL, to: temporary)
        let sourceDigest = try Self.digest(of: sourceURL)
        let copiedDigest = try Self.digest(of: temporary)
        guard sourceDigest == copiedDigest else { throw ManagedFileError.verificationFailed }
        try Task.checkCancellation()
        try manager.moveItem(at: temporary, to: destination)
        // Validate the committed path before returning anything that can be saved to SQLite.
        _ = try url(for: relativePath)
        committed = true
        return ManagedCopy(relativePath: relativePath, sha256: sourceDigest)
    }

    // The caller holds the dropped/selected file's security scope until this returns.
    func importFile(sourceURL: URL, database: LibraryDatabase) async throws -> String {
        let copyTask = Task.detached(priority: .userInitiated) { () throws -> (ManagedCopy, ScannedFile) in
            let copy = try self.copy(sourceURL: sourceURL)
            do {
                let copiedURL = try self.url(for: copy.relativePath)
                let values = try copiedURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey,
                    .contentModificationDateKey, .creationDateKey])
                let metadata = ScannedFile(relativePath: copy.relativePath, name: sourceURL.lastPathComponent,
                    typeIdentifier: values.contentType?.identifier ?? UTType.data.identifier,
                    bytes: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate,
                    createdAt: values.creationDate)
                return (copy, metadata)
            } catch {
                try? self.discardUncommittedCopy(copy.relativePath)
                throw error
            }
        }
        let (copy, metadata) = try await withTaskCancellationHandler {
            try await copyTask.value
        } onCancel: {
            copyTask.cancel()
        }
        do {
            try Task.checkCancellation()
            return try await database.saveImportedFile(metadata: metadata, copy: copy,
                                                       originalPath: sourceURL.standardizedFileURL.path)
        } catch {
            try? discardUncommittedCopy(copy.relativePath)
            throw error
        }
    }

    func url(for relativePath: String) throws -> URL {
        guard Self.isValidRelativePath(relativePath) else { throw ManagedFileError.invalidPath }
        try validateDirectory(root)
        let components = relativePath.split(separator: "/").map(String.init)
        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw ManagedFileError.invalidPath }
            if index == components.count - 1 {
                guard values.isRegularFile == true else { throw ManagedFileError.missingCopy }
            } else {
                guard values.isDirectory == true else { throw ManagedFileError.invalidPath }
            }
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard current.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonicalRoot + "/") else {
            throw ManagedFileError.invalidPath
        }
        return current
    }

    // Used only when SQLite rejects a newly copied file. Successful copies have no delete action.
    func discardUncommittedCopy(_ relativePath: String) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count == 2, UUID(uuidString: components[0]) != nil else {
            throw ManagedFileError.invalidPath
        }
        let copiedFile = try url(for: relativePath)
        let manager = FileManager.default
        try manager.removeItem(at: copiedFile)
        let directory = copiedFile.deletingLastPathComponent()
        if try manager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try manager.removeItem(at: directory)
        }
    }

    static func isValidRelativePath(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0") else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func prepareRoot() throws {
        guard root.isFileURL else { throw ManagedFileError.invalidPath }
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try validateDirectory(root)
    }

    private func validateDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw ManagedFileError.invalidPath }
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw ManagedFileError.invalidPath
        }
    }

    private static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum ManagedFileError: LocalizedError {
    case invalidSource, invalidPath, missingCopy, verificationFailed

    var errorDescription: String? {
        switch self {
        case .invalidSource: "只能为可访问的普通文件保存副本。"
        case .invalidPath: "托管副本位置无效，无法访问资料库外部或符号链接。"
        case .missingCopy: "托管副本已不可用，请检查应用数据目录。"
        case .verificationFailed: "复制后校验不一致，可能复制时原文件发生了变化。请重试。"
        }
    }
}
