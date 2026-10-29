import CoreServices
import Foundation

/// One stream for one already-authorized directory. The caller owns its security scope.
@MainActor
final class FolderWatcher {
    private final class Handler: Sendable {
        let changed: @MainActor @Sendable () -> Void
        let rootPrefix: String
        init(root: URL, _ changed: @escaping @MainActor @Sendable () -> Void) {
            self.changed = changed
            rootPrefix = root.standardizedFileURL.path + "/"
        }
    }
    private var stream: FSEventStreamRef?

    init(root: URL, changed: @escaping @MainActor @Sendable () -> Void) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else {
            throw AccessError.scan
        }
        let handler = Handler(root: root, changed)
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
                let ordinary = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated |
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemModified |
                    kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemChangeOwner |
                    kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsFile |
                    kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagOwnEvent)
                let itemTypes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir)
                // Without UseCFTypes, FSEvents supplies a C string array.
                let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                let relevant = (0..<count).contains { index in
                    let flag = flags[index]
                    if flag == UInt32(kFSEventStreamEventFlagHistoryDone) { return false }
                    // Drops, renames, hard links and unknown flags still rescan.
                    guard flag & ~ordinary == 0, flag & itemTypes != 0 else { return true }
                    let path = String(cString: paths[index])
                    guard path.hasPrefix(handler.rootPrefix) else { return true }
                    let relative = path.dropFirst(handler.rootPrefix.count)
                    return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
                }
                if relevant { handler.changed() }
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
