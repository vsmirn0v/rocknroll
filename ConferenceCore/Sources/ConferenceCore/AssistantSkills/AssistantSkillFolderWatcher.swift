import Dispatch
import Foundation

/// Watches the active Rock Assistant root directory (`Skills/`, `Prompts/`, `Knowledge/`)
/// for external edits made in Obsidian, Git, or Finder/Files and fires a debounced callback.
public final class AssistantSkillFolderWatcher: @unchecked Sendable {
    public let rootURL: URL
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferencecore.skill-folder-watcher", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?

    public init(
        rootURL: URL,
        debounceInterval: TimeInterval = 0.3,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.rootURL = rootURL
        self.debounceInterval = max(0.05, debounceInterval)
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        stopLocked()

        let directories = [
            rootURL,
            rootURL.appendingPathComponent("Skills", isDirectory: true),
            rootURL.appendingPathComponent("Prompts", isDirectory: true),
            rootURL.appendingPathComponent("Knowledge", isDirectory: true),
        ]

        for dir in directories {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebouncedNotification()
            }
            source.setCancelHandler {
                close(fd)
            }
            sources.append(source)
            source.resume()
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopLocked()
        lock.unlock()
    }

    private func stopLocked() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        let existing = sources
        sources.removeAll()
        for source in existing {
            source.cancel()
        }
    }

    private func scheduleDebouncedNotification() {
        lock.lock()
        debounceWorkItem?.cancel()
        let callback = onChange
        let work = DispatchWorkItem {
            callback()
        }
        debounceWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
