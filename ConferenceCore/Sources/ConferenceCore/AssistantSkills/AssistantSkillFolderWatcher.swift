import Darwin
import Dispatch
import Foundation

/// Watches the active Rock Assistant root directory (`Skills/`, `Prompts/`, `Knowledge/`)
/// for external edits made in Obsidian, Git, or Finder/Files and fires a debounced callback.
public final class AssistantSkillFolderWatcher: @unchecked Sendable {
    private struct WatchedSource {
        let isDirectory: Bool
        let inode: UInt64
        let source: DispatchSourceFileSystemObject
    }

    public let rootURL: URL
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferencecore.skill-folder-watcher", qos: .utility)
    private var sourcesByPath: [String: WatchedSource] = [:]
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
        let fm = FileManager.default
        let directories = [
            rootURL,
            rootURL.appendingPathComponent("Skills", isDirectory: true),
            rootURL.appendingPathComponent("Prompts", isDirectory: true),
            rootURL.appendingPathComponent("Knowledge", isDirectory: true),
        ]

        var desiredTargets: [(path: String, isDirectory: Bool, inode: UInt64)] = []
        var seenPaths: Set<String> = []
        func currentInode(_ path: String) -> UInt64? {
            var st = Darwin.stat()
            guard Darwin.lstat(path, &st) == 0 else { return nil }
            return UInt64(st.st_ino)
        }

        for dir in directories where fm.fileExists(atPath: dir.path) {
            let path = dir.standardizedFileURL.path
            if let inode = currentInode(path), seenPaths.insert(path).inserted {
                desiredTargets.append((path, true, inode))
            }
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
                let path = fileURL.standardizedFileURL.path
                if let inode = currentInode(path), seenPaths.insert(path).inserted {
                    desiredTargets.append((path, false, inode))
                    fileCount += 1
                    if fileCount >= 128 { break }
                }
            }
        }

        // Cancel stale or replaced (atomic rename -> new inode) file descriptors while keeping
        // unchanged file/directory watches open without churn.
        let desiredByPath = Dictionary(uniqueKeysWithValues: desiredTargets.map { ($0.path, ($0.isDirectory, $0.inode)) })
        for (path, existing) in sourcesByPath {
            if let target = desiredByPath[path], target.0 == existing.isDirectory, target.1 == existing.inode {
                continue
            }
            sourcesByPath.removeValue(forKey: path)
            existing.source.cancel()
        }

        for target in desiredTargets {
            if sourcesByPath[target.path] != nil { continue }
            let fd = open(target.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let mask: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .extend, .attrib, .link]
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: mask,
                queue: queue
            )
            let isDirectory = target.isDirectory
            source.setEventHandler { [weak self, weak source] in
                let flags = source?.data ?? []
                let refresh = isDirectory || flags.contains(.delete) || flags.contains(.rename)
                self?.scheduleDebouncedNotification(refreshSources: refresh)
            }
            source.setCancelHandler {
                close(fd)
            }
            sourcesByPath[target.path] = WatchedSource(isDirectory: isDirectory, inode: target.inode, source: source)
            source.resume()
        }
    }

    private func stopLocked(cancelDebounce: Bool = true) {
        if cancelDebounce {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            needsSourceRefresh = false
        }
        let existing = Array(sourcesByPath.values)
        sourcesByPath.removeAll()
        for entry in existing {
            entry.source.cancel()
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
