import CoreServices
import Foundation

/// One stream for one already-authorized directory. The caller owns its security scope.
@MainActor
final class FolderWatcher {
    private final class Handler: Sendable {
        let changed: @MainActor @Sendable () -> Void
        init(_ changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
    }
    private var stream: FSEventStreamRef?

    init(root: URL, changed: @escaping @MainActor @Sendable () -> Void) throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else {
            throw AccessError.scan
        }
        let handler = Handler(changed)
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
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, _, flags, _ in
            guard let info, (0..<count).contains(where: { flags[$0] & UInt32(kFSEventStreamEventFlagHistoryDone) == 0 }) else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            // The stream is scheduled exclusively on the main dispatch queue.
            MainActor.assumeIsolated { handler.changed() }
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
