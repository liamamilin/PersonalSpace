import Foundation

struct LibraryLocation: Identifiable, Sendable, Equatable {
    let id: String
    let root: URL
    var databaseURL: URL { root.appendingPathComponent(id == "original" ? "Library.sqlite" : "library.sqlite") }
    var vault: URL { root.appendingPathComponent("Vault", isDirectory: true) }
    var title: String { id == "original" ? "原始资料库" : "恢复的资料库 · " + String(id.prefix(8)) }
}

/// A next-launch pointer and one retained predecessor; databases are never hot-swapped.
struct ActiveLibrary: Sendable {
    struct Selection: Codable, Equatable {
        var active = "original"
        var previous: String?
    }
    let base: URL

    static func application() throws -> ActiveLibrary {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let base = support.appendingPathComponent("PersonalSpace", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ActiveLibrary(base: base)
    }

    func selection() throws -> Selection {
        let file = base.appendingPathComponent("active-library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Selection() }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ActiveLibraryError.invalidPointer }
        let result = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: file))
        _ = try location(result.active)
        if let previous = result.previous { _ = try location(previous) }
        return result
    }

    func location(_ id: String) throws -> LibraryLocation {
        guard id == "original" || UUID(uuidString: id) != nil else { throw ActiveLibraryError.invalidPointer }
        let root = id == "original" ? base : base.appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        return LibraryLocation(id: id, root: root)
    }

    func current() throws -> LibraryLocation {
        let current = try location(selection().active)
        try Self.requireDirectory(base)
        if current.id != "original" {
            try Self.requireDirectory(current.root.deletingLastPathComponent())
            try Self.requireDirectory(current.root)
            let values = try current.databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ActiveLibraryError.invalidPointer }
        }
        return current
    }

    func newRestoreLocation() throws -> LibraryLocation {
        let parent = base.appendingPathComponent("Libraries", isDirectory: true)
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        try Self.requireDirectory(parent)
        return try location(UUID().uuidString)
    }

    func scheduleSwitch(to target: LibraryLocation, from current: LibraryLocation) throws {
        guard target == (try location(target.id)), current == (try location(current.id)) else {
            throw ActiveLibraryError.invalidPointer
        }
        try Self.requireDirectory(target.root)
        if target.id != "original" { try Self.requireDirectory(target.root.deletingLastPathComponent()) }
        let values = try target.databaseURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ActiveLibraryError.invalidPointer }
        let database = try LibraryDatabase(path: target.databaseURL.path)
        defer { try? database.queue.close() }
        try LibraryBackup.validateForUse(database: database, vaultRoot: target.vault)
        let previous = target.id == current.id ? try selection().active : current.id
        let next = Selection(active: target.id, previous: previous == target.id ? nil : previous)
        try JSONEncoder().encode(next).write(to: base.appendingPathComponent("active-library.json"), options: .atomic)
    }

    static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ActiveLibraryError.invalidPointer }
    }
}

enum ActiveLibraryError: LocalizedError {
    case invalidPointer, backupChanged
    var errorDescription: String? {
        switch self {
        case .invalidPointer: "资料库目录无法验证，未切换资料库；已有目录保留。"
        case .backupChanged: "备份在确认期间发生变化，请重新选择并核对。未启用此备份。"
        }
    }
}
