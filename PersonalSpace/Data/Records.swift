import Foundation
import GRDB
import UniformTypeIdentifiers

struct FolderSource: Decodable, FetchableRecord, Identifiable, Sendable {
    var id: String
    var name: String
    var path: String
    var bookmark: Data
    var lastScannedAt: Date?
    var lastError: String?
    var fileCount: Int
}

struct PersonalObject: Decodable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: String
    var kind: String
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var itemCount: Int
}

struct LibraryFile: Decodable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: String
    var sourceID: String
    var relativePath: String
    var name: String
    var typeIdentifier: String
    var bytes: Int64
    var modifiedAt: Date?
    var createdAt: Date?
    var isAvailable: Bool
    var sourceName: String
    var sourcePath: String
    var sourceError: String?
    var managedCopyPath: String? = nil
    var managedSHA256: String? = nil
    var managedAt: Date? = nil

    var modifiedSortDate: Date { modifiedAt ?? .distantPast }
    var kind: String { UTType(typeIdentifier)?.localizedDescription ?? "文件" }
    var fullPath: String { URL(fileURLWithPath: sourcePath).appendingPathComponent(relativePath).path }
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct ScannedFile: Sendable {
    var relativePath: String
    var name: String
    var typeIdentifier: String
    var bytes: Int64
    var modifiedAt: Date?
    var createdAt: Date?
}

enum FileSort: String, CaseIterable, Identifiable, Sendable {
    case name, kind, modified, size, source
    var id: Self { self }
    var title: String {
        switch self {
        case .name: "名称"
        case .kind: "类型"
        case .modified: "修改日期"
        case .size: "大小"
        case .source: "来源"
        }
    }
    var sql: String {
        switch self {
        case .name: "i.name COLLATE NOCASE"
        case .kind: "i.typeIdentifier"
        case .modified: "i.modifiedAt"
        case .size: "i.bytes"
        case .source: "s.name COLLATE NOCASE"
        }
    }
}

struct FileQuery: Sendable {
    var search = ""
    var sourceID: String?
    var objectID: String? = nil
    var managedOnly = false
    var sort: FileSort = .name
    var ascending = true
    var limit = 500
}
