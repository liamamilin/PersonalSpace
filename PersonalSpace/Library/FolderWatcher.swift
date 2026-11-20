import CoreServices
import Foundation

/// One stream for one already-authorized directory. The caller owns its security scope.
@MainActor
final class FolderWatcher {
    private final class Handler: Sendable {
        let changed: @MainActor @Sendable ([String]?) -> Void
        let rootPrefixes: Set<String>
        let exclusions: FolderScanExclusions
        init(root: URL, exclusions: FolderScanExclusions, _ changed: @escaping @MainActor @Sendable ([String]?) -> Void) {
            self.changed = changed
            rootPrefixes = [root.standardizedFileURL.path + "/", root.resolvingSymlinksInPath().standardizedFileURL.path + "/"]
            self.exclusions = exclusions
        }
    }
    private var stream: FSEventStreamRef?

    init(root: URL, exclusions: FolderScanExclusions = FolderScanExclusions(),
         changed: @escaping @MainActor @Sendable ([String]?) -> Void) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else {
            throw AccessError.scan
        }
        let handler = Handler(root: root, exclusions: exclusions, changed)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Handler>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            // The stream is scheduled exclusively on the main dispatch queue.
            MainActor.assumeIsolated {
                // Without UseCFTypes, FSEvents supplies a C string array.
                let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                let events = (0..<count).map { (path: String(cString: paths[$0]), flags: flags[$0]) }
                if let targets = FolderWatcher.pathsToScan(rootPrefixes: handler.rootPrefixes,
                    exclusions: handler.exclusions, events: events) {
                    if !targets.isEmpty { handler.changed(targets) }
                } else { handler.changed(nil) }
            }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            throw FolderWatchError.startFailed
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            stop()
            throw FolderWatchError.startFailed
        }
    }

    /// nil means the complete source must be reconciled; [] means no indexed change.
    static func pathsToScan(rootPrefixes: Set<String>, exclusions: FolderScanExclusions,
                            events: [(path: String, flags: FSEventStreamEventFlags)]) -> [String]? {
        let fullScanFlags = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let directoryStructureFlags = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod |
            kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemFinderInfoMod)
        var changed: Set<String> = []
        for (path, flag) in events {
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            if exclusions.contains(URL(fileURLWithPath: path)) { continue }
            if flag & fullScanFlags != 0 { return nil }
            let subtree = flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
            guard let prefix = rootPrefixes.first(where: { path.hasPrefix($0) }) else {
                if rootPrefixes.contains(path + "/"), subtree || flag & UInt32(kFSEventStreamEventFlagItemRemoved |
                    kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod |
                    kFSEventStreamEventFlagItemChangeOwner) != 0 { return nil }
                continue
            }
            let relative = String(path.dropFirst(prefix.count))
            let components = relative.split(separator: "/")
            if components.contains(where: { $0.hasPrefix(".") }) {
                if flag & UInt32(kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink) != 0 {
                    let parent = components.dropLast().joined(separator: "/")
                    if parent.isEmpty { return nil }
                    changed.insert(parent)
                }
                continue
            }
            // FileEvents supplies child paths. A directory's mtime/data or tag-only
            // event must not turn each cache-file change into a subtree walk.
            // Creation, rename, removal, permissions and visibility still reconcile.
            if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0,
               !subtree, flag & directoryStructureFlags == 0 { continue }
            // Coalesced events require this subtree, not the entire source. Dropped
            // events and source changes above remain conservative full reconciliations.
            changed.insert(relative)
        }
        return changed.sorted()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit { stop() }
}

private enum FolderWatchError: LocalizedError {
    case startFailed
    var errorDescription: String? { "无法启动文件夹变化监听。请重新授权来源；仍可手动刷新。" }
}
