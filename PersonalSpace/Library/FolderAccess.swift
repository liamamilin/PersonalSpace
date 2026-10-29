import Foundation

struct FolderAccess {
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ source: FolderSource) throws -> (url: URL, renewedBookmark: Data?) {
        guard !source.needsAuthorization else { throw AccessError.authorization }
        var stale = false
        let url = try URL(resolvingBookmarkData: source.bookmark,
                          options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw AccessError.authorization }
        do {
            let data = stale ? try bookmark(for: url) : nil
            return (url, data)
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    static func fileURL(relativePath: String, root: URL) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw AccessError.authorization
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        // Reject symlink substitution in any component, including after indexing.
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(canonicalRoot + "/") else { throw AccessError.authorization }
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw AccessError.missing }
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AccessError.authorization }
        }
        return candidate
    }
}

enum AccessError: LocalizedError {
    case authorization, missing, scan
    var errorDescription: String? {
        switch self {
        case .authorization: "无法访问此位置，请在来源设置中重新选择此文件夹。"
        case .missing: "原位置已不可用。文件可能已被移动或移除，请刷新来源。"
        case .scan: "未能完整读取文件夹，旧文件状态已保留。请检查权限后重试。"
        }
    }
}
