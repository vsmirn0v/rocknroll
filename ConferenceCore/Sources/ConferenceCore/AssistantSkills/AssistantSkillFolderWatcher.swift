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
    private var needsSourceRefresh = false

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
        rebuildSourcesLocked()
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        stopLocked()
        lock.unlock()
    }

    private func rebuildSourcesLocked() {
        stopLocked(cancelDebounce: false)

        let fm = FileManager.default
        let directories = [
            rootURL,
            rootURL.appendingPathComponent("Skills", isDirectory: true),
            rootURL.appendingPathComponent("Prompts", isDirectory: true),
            rootURL.appendingPathComponent("Knowledge", isDirectory: true),
        ]

        var watchedPaths: [URL] = []
        for dir in directories where fm.fileExists(atPath: dir.path) {
            watchedPaths.append(dir)
        }

        // Also watch individual .md file descriptors so non-atomic in-place edits
        // (e.g. O_WRONLY | O_TRUNC in external editors) fire VNODE events.
        var fileCount = 0
        for dir in directories.dropFirst() where fm.fileExists(atPath: dir.path) {
            guard fileCount < 128,
                  let entries = try? fm.contentsOfDirectory(
                      at: dir,
                      includingPropertiesForKeys: nil,
                      options: [.skipsHiddenFiles]
                  ) else { continue }
            for fileURL in entries where fileURL.pathExtension.lowercased() == "md" {
                watchedPaths.append(fileURL)
                fileCount += 1
                if fileCount >= 128 { break }
            }
        }

        for target in watchedPaths {
            let isDirectory = directories.contains(where: { $0.path == target.path })
            let fd = open(target.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let mask: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .extend, .attrib, .link]
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: mask,
                queue: queue
            )
            source.setEventHandler { [weak self, weak source] in
                let flags = source?.data ?? []
                let refresh = isDirectory || flags.contains(.delete) || flags.contains(.rename)
                self?.scheduleDebouncedNotification(refreshSources: refresh)
            }
            source.setCancelHandler {
                close(fd)
            }
            sources.append(source)
            source.resume()
        }
    }

    private func stopLocked(cancelDebounce: Bool = true) {
        if cancelDebounce {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            needsSourceRefresh = false
        }
        let existing = sources
        sources.removeAll()
        for source in existing {
            source.cancel()
        }
    }

    private func scheduleDebouncedNotification(refreshSources: Bool) {
        lock.lock()
        if refreshSources {
            needsSourceRefresh = true
        }
        debounceWorkItem?.cancel()
        let callback = onChange
        let work = DispatchWorkItem { [weak self] in
            if let self {
                self.lock.lock()
                let shouldRebuild = self.needsSourceRefresh
                self.needsSourceRefresh = false
                if shouldRebuild {
                    self.rebuildSourcesLocked()
                }
                self.lock.unlock()
            }
            callback()
        }
        debounceWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
