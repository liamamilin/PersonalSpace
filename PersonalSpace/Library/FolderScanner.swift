import Foundation
import UniformTypeIdentifiers
import Darwin

/// Shared by enumeration and FSEvents so the app cannot index or watch its own writes.
struct FolderScanExclusions: Sendable {
    private let directories: Set<String>
    private let files: Set<String>

    init(databasePath: String? = nil, directories: [URL] = []) {
        func paths(_ url: URL) -> [String] {
            [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path]
        }
        self.directories = Set(directories.flatMap(paths))
        if let databasePath, databasePath != ":memory:" {
            files = Set(paths(URL(fileURLWithPath: databasePath)).flatMap { path in
                [path, path + "-wal", path + "-shm", path + "-journal"]
            })
        } else { files = [] }
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return files.contains(path) || directories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

struct FolderScanIssue: Codable, Sendable, Identifiable {
    var path: String
    var reason: String
    var disappeared: Bool
    var id: String { path }

    init(path: String, error: Error) {
        self.path = path
        if let access = error as? AccessError, case .cloudDirectory = access {
            reason = "云端目录尚未下载，未遍历其内容"
            disappeared = false
            return
        }
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        disappeared = (error.domain == NSCocoaErrorDomain && [4, 260].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == 2)
            || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == 2)
        if disappeared { reason = "扫描期间已移走或删除" }
        else if (error.domain == NSCocoaErrorDomain && error.code == 257)
            || (error.domain == NSPOSIXErrorDomain && [1, 13].contains(error.code))
            || (underlying?.domain == NSPOSIXErrorDomain && [1, 13].contains(underlying?.code ?? 0)) {
            reason = "系统拒绝读取，权限不足"
        } else { reason = "暂时无法读取，资料记录已保留" }
    }
}

struct FolderScanReport: Codable, Sendable {
    var fileCount = 0
    var completedAt = Date()
    var issues: [FolderScanIssue] = []
    var unreadable: [FolderScanIssue] { issues.filter { !$0.disappeared } }
}

// Directory-descriptor validation and bulk enumeration follow Oil Find (MIT).
// The adapted decoder and its license are in NativeScan/ and THIRD_PARTY_NOTICES.md.
struct FolderScanner {
    /// The same visibility/access rules as indexing, without file records or database writes.
    static func count(root: URL, exclusions: FolderScanExclusions = FolderScanExclusions(),
                      preferBulkMetadata: Bool = true,
                      progress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> FolderScanReport {
        try read(root: root, sourceID: "", database: nil, exclusions: exclusions,
                 scope: nil, preferBulkMetadata: preferBulkMetadata, progress: progress)
    }

    @discardableResult
    static func scan(root: URL, sourceID: String, database: LibraryDatabase,
                     exclusions suppliedExclusions: FolderScanExclusions? = nil,
                     scope: String? = nil,
                     preferBulkMetadata: Bool = true,
                     progress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> FolderScanReport {
        try read(root: root, sourceID: sourceID, database: database,
                 exclusions: suppliedExclusions ?? FolderScanExclusions(databasePath: database.queue.path),
                 scope: scope, preferBulkMetadata: preferBulkMetadata, progress: progress)
    }

    private static func read(root: URL, sourceID: String, database: LibraryDatabase?,
                             exclusions: FolderScanExclusions, scope: String?, preferBulkMetadata: Bool,
                             progress: @escaping @Sendable (Int) -> Void) throws -> FolderScanReport {
        guard !exclusions.contains(root) else { throw AccessError.scan }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              rootValues.isPackage != true else { throw AccessError.scan }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        var original = stat()
        guard Darwin.lstat(canonical.path, &original) == 0, original.st_mode & S_IFMT == S_IFDIR else { throw AccessError.scan }
        let rootFD = Darwin.open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError() }
        defer { Darwin.close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, sameDirectory(opened, original) else { throw AccessError.authorization }
        guard opened.st_flags & UInt32(SF_DATALESS) == 0 else { throw AccessError.cloudDirectory }

        let scanID = UUID().uuidString
        var report = FolderScanReport()
        var batch: [ScannedFile] = []
        batch.reserveCapacity(512)
        var lastProgress = ContinuousClock.now
        var typeCache: [String: String] = [:]
        var cacheOrder: [String] = []
        var eviction = 0
        let scratchSize = 256 * 1024
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 8)
        let entries = UnsafeMutablePointer<ps_scan_entry>.allocate(capacity: scratchSize / 32)
        defer { scratch.deallocate(); entries.deallocate() }

        func fileURL(_ relative: String) -> URL { relative.isEmpty ? canonical : canonical.appendingPathComponent(relative) }
        func record(_ relative: String, _ error: Error) {
            guard !exclusions.contains(fileURL(relative)), !report.issues.contains(where: { $0.path == relative }) else { return }
            report.issues.append(FolderScanIssue(path: relative, error: error))
        }
        func publishProgress() {
            let now = ContinuousClock.now
            if lastProgress.duration(to: now) >= .milliseconds(250) {
                progress(report.fileCount); lastProgress = now
            }
        }
        func flush() throws {
            guard let database, !batch.isEmpty else { return }
            try database.saveBatch(batch, sourceID: sourceID, scanID: scanID)
            batch.removeAll(keepingCapacity: true)
            publishProgress()
        }
        func identifier(_ name: String) -> String {
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty else { return UTType.data.identifier }
            if let cached = typeCache[ext] { return cached }
            let type = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
            if cacheOrder.count < 512 { cacheOrder.append(ext) }
            else { typeCache[cacheOrder[eviction]] = nil; cacheOrder[eviction] = ext; eviction = (eviction + 1) % 512 }
            typeCache[ext] = type
            return type
        }
        func append(_ relative: String, name: String, size: UInt64, modified: Date, created: Date) throws {
            report.fileCount += 1
            guard database != nil else {
                if report.fileCount.isMultiple(of: 512) { publishProgress() }
                return
            }
            batch.append(ScannedFile(relativePath: relative, name: name, typeIdentifier: identifier(name),
                bytes: Int64(clamping: size), modifiedAt: modified, createdAt: created))
            if batch.count >= 512 { try flush() }
        }
        func skipDirectory(_ relative: String, value: stat) throws -> Bool {
            if value.st_flags & UInt32(UF_HIDDEN) != 0 || exclusions.contains(fileURL(relative)) { return true }
            if value.st_flags & UInt32(SF_DATALESS) != 0 { throw AccessError.cloudDirectory }
            // Only directories need LaunchServices package/visibility metadata.
            let values = try fileURL(relative).resourceValues(forKeys: [.isPackageKey, .isHiddenKey, .isSymbolicLinkKey])
            if values.isPackage == true || values.isHidden == true || values.isSymbolicLink == true { return true }
            return false
        }
        func openDirectory(_ parent: Int32, name: String, expected: stat) throws -> Int32 {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw posixError() }
            var value = stat()
            guard fstat(fd, &value) == 0, sameDirectory(value, expected) else {
                Darwin.close(fd); throw AccessError.authorization
            }
            return fd
        }
        struct Child { var name: String; var relative: String; var inode: UInt64; var device: Int32 }
        func walk(_ fd: Int32, relative: String) throws {
            try Task.checkCancellation()
            guard let reader = ps_directory_reader_create(fd, preferBulkMetadata ? 1 : 0, database == nil ? 1 : 0) else { throw posixError() }
            defer { ps_directory_reader_destroy(reader) }
            while true {
                try Task.checkCancellation()
                var finished = false
                // Copy child names before recursion reuses the bulk buffers.
                let children: [Child] = try autoreleasepool {
                    let count = ps_directory_reader_next(reader, scratch, scratchSize, entries, Int32(scratchSize / 32))
                    if count < 0 { record(relative, posixError()); finished = true; return [] }
                    if count == 0 { finished = true; return [] }
                    var children: [Child] = []
                    for index in 0..<Int(count) {
                        try Task.checkCancellation()
                        let entry = entries[index]
                        guard let pointer = entry.name, let name = String(validatingCString: pointer) else {
                            record(relative, posixError(EILSEQ)); continue
                        }
                        if name == "." || name == ".." || name.hasPrefix(".") { continue }
                        let path = relative.isEmpty ? name : relative + "/" + name
                        if exclusions.contains(fileURL(path)) { continue }
                        if entry.error != 0 { record(path, posixError(entry.error)); continue }
                        if entry.flags & UInt32(UF_HIDDEN) != 0 || entry.type == 2 { continue }
                        if entry.type == 1 {
                            if entry.flags & UInt32(SF_DATALESS) != 0 { record(path, AccessError.cloudDirectory); continue }
                            children.append(Child(name: name, relative: path, inode: entry.inode, device: entry.dev))
                        } else if entry.type == 0 {
                            if entry.needs_hidden_check != 0 {
                                do { if try fileURL(path).resourceValues(forKeys: [.isHiddenKey]).isHidden == true { continue } }
                                catch { record(path, error); continue }
                            }
                            try append(path, name: name, size: entry.size,
                                modified: date(entry.modified_seconds, entry.modified_nanoseconds),
                                created: date(entry.created_seconds, entry.created_nanoseconds))
                        }
                    }
                    return children
                }
                if finished { break }
                for child in children {
                    try Task.checkCancellation()
                    var expected = stat()
                    // Verify against the identity returned by the parent's bulk read.
                    guard fstatat(fd, child.name, &expected, AT_SYMLINK_NOFOLLOW) == 0 else {
                        record(child.relative, posixError()); continue
                    }
                    guard expected.st_mode & S_IFMT == S_IFDIR,
                          UInt64(expected.st_ino) == child.inode, Int32(expected.st_dev) == child.device else {
                        record(child.relative, AccessError.authorization); continue
                    }
                    let childFD: Int32
                    do {
                        if try skipDirectory(child.relative, value: expected) { continue }
                        childFD = try openDirectory(fd, name: child.name, expected: expected)
                    }
                    catch { record(child.relative, error); continue }
                    defer { Darwin.close(childFD) }
                    // Database/cancellation errors must propagate, not become skipped files.
                    try walk(childFD, relative: child.relative)
                }
            }
        }
        func finish() throws -> FolderScanReport {
            try Task.checkCancellation()
            try flush()
            guard report.issues.allSatisfy({ !$0.path.isEmpty }) else { throw AccessError.scan }
            var current = stat()
            guard lstat(root.path, &current) == 0, sameDirectory(current, original) else { throw AccessError.scan }
            report.completedAt = Date()
            try database?.finishScan(sourceID: sourceID, scanID: scanID, scope: scope, report: report)
            progress(report.fileCount)
            return report
        }
        if let scope {
            let parts = scope.split(separator: "/").map(String.init)
            guard !scope.isEmpty, !scope.hasPrefix("/"), parts.joined(separator: "/") == scope,
                  !parts.contains(".."), !parts.contains(".") else { throw AccessError.authorization }
            var parent = rootFD
            var held: [Int32] = []
            defer { for fd in held.reversed() { Darwin.close(fd) } }
            var relative = ""
            for part in parts.dropLast() {
                relative = relative.isEmpty ? part : relative + "/" + part
                if part.hasPrefix(".") || exclusions.contains(fileURL(relative)) { return try finish() }
                var value = stat()
                guard fstatat(parent, part, &value, AT_SYMLINK_NOFOLLOW) == 0 else { record(relative, posixError()); return try finish() }
                // The indexed descendant no longer belongs to a traversable
                // directory. Reconcile this scope without opening its ancestor.
                if value.st_mode & S_IFMT != S_IFDIR { return try finish() }
                let skip: Bool
                do {
                    skip = try skipDirectory(relative, value: value)
                    if !skip {
                        let fd = try openDirectory(parent, name: part, expected: value)
                        held.append(fd); parent = fd
                    }
                } catch { record(relative, error); return try finish() }
                if skip { return try finish() }
            }
            let name = parts.last!
            if name.hasPrefix(".") || exclusions.contains(fileURL(scope)) { return try finish() }
            var value = stat()
            guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { record(scope, posixError()); return try finish() }
            if value.st_mode & S_IFMT == S_IFLNK || value.st_flags & UInt32(UF_HIDDEN) != 0 { return try finish() }
            if value.st_mode & S_IFMT == S_IFREG {
                let hidden: Bool
                do { hidden = try fileURL(scope).resourceValues(forKeys: [.isHiddenKey]).isHidden == true }
                catch { record(scope, error); return try finish() }
                if hidden { return try finish() }
                try append(scope, name: name, size: UInt64(max(0, value.st_size)),
                    modified: date(Int64(value.st_mtimespec.tv_sec), Int64(value.st_mtimespec.tv_nsec)),
                    created: date(Int64(value.st_birthtimespec.tv_sec), Int64(value.st_birthtimespec.tv_nsec)))
            } else if value.st_mode & S_IFMT == S_IFDIR {
                let skip: Bool
                do {
                    skip = try skipDirectory(scope, value: value)
                    if !skip {
                        let fd = try openDirectory(parent, name: name, expected: value)
                        held.append(fd)
                    }
                } catch { record(scope, error); return try finish() }
                if skip { return try finish() }
                try walk(held.last!, relative: scope)
            }
        } else { try walk(rootFD, relative: "") }
        return try finish()
    }

    private static func posixError(_ code: Int32 = errno) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    private static func sameDirectory(_ a: stat, _ b: stat) -> Bool {
        a.st_mode & S_IFMT == S_IFDIR && b.st_mode & S_IFMT == S_IFDIR && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    private static func date(_ seconds: Int64, _ nanoseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}
