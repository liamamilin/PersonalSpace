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

struct MatterRecord: Decodable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: String
    var kind: String
    var title: String
    var status: String
    var objectID: String?
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var itemCount: Int
}

struct FactRecord: Decodable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: String
    var matterID: String
    var key: String
    var valueText: String
    var valueType: String
    var state: String
    var sourceItemID: String?
    var sourceExcerpt: String?
    var origin: String
}

struct ActionRecord: Decodable, FetchableRecord, Identifiable, Sendable, Equatable {
    var id: String
    var matterID: String?
    var title: String
    var dueDate: Date?
    var remindAt: Date?
    var state: String
    var dateConfirmed: Bool
    var createdAt: Date
    var updatedAt: Date
    var matterTitle: String?
}

// These drafts are the concrete order editor's input to one database transaction.
struct MatterDraft: Sendable {
    var id = UUID().uuidString
    var kind = "order"
    var title = ""
    var status = "active"
    var objectID: String? = nil
    var notes = ""
    var itemIDs: [String] = []
    var facts: [FactDraft] = []
    var action: ActionDraft? = nil
}

struct FactDraft: Identifiable, Sendable, Equatable {
    var id = UUID().uuidString
    var key = ""
    var valueText = ""
    var valueType = "text"
    var state = "candidate"
    var sourceItemID: String? = nil
    var sourceExcerpt: String? = nil
    var origin = "user"
}

struct ActionDraft: Identifiable, Sendable, Equatable {
    var id = UUID().uuidString
    var title = ""
    var dueDate: Date? = nil
    var remindAt: Date? = nil
    var state = "needs_date"
    var dateConfirmed = false
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
    var textIndexedAt: Date? = nil
    var itemKind = "file"
    var photoLocalIdentifier: String? = nil
    var sensitivity = "normal"

    var modifiedSortDate: Date { modifiedAt ?? .distantPast }
    var isPhoto: Bool { itemKind == "photo" }
    var kind: String { isPhoto ? "照片" : UTType(typeIdentifier)?.localizedDescription ?? "文件" }
    var fullPath: String { isPhoto ? "照片图库" : URL(fileURLWithPath: sourcePath).appendingPathComponent(relativePath).path }
    var size: String { isPhoto ? "—" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct ScannedFile: Sendable {
    var relativePath: String
    var name: String
    var typeIdentifier: String
    var bytes: Int64
    var modifiedAt: Date?
    var createdAt: Date?
}

struct ScannedPhoto: Sendable {
    var localIdentifier: String
    var name: String
    var createdAt: Date?
    var modifiedAt: Date?
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
    var matterID: String? = nil
    var managedOnly = false
    var searchBody = false
    var sort: FileSort = .name
    var ascending = true
    var limit = 500
}
