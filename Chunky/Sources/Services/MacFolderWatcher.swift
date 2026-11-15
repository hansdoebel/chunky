import CoreServices
import Foundation

nonisolated final class MacFolderWatcher: FolderWatching {
    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?

    func start(paths: [String], onChange: @escaping () -> Void) {
        stop()
        let watched = paths.filter { !$0.isEmpty }
        guard !watched.isEmpty else { return }
        self.onChange = onChange
        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, raw, _, _, _, _ in
            guard let raw else { return }
            let watcher = Unmanaged<MacFolderWatcher>.fromOpaque(raw).takeUnretainedValue()
            let handler = watcher.onChange
            DispatchQueue.main.async {
                handler?()
            }
        }
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
