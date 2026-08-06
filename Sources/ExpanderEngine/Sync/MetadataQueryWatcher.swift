// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import AppKit
import Foundation

public final class MetadataQueryWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    private let fileName: String
    private let directoryURL: URL
    /// §2.5: the exact file we track. The predicate used to match on filename
    /// alone, so the watcher fired for *any* file called `DevType-snippets.json`
    /// anywhere in the user's ubiquitous containers.
    private let trackedURL: URL
    private let notificationCenter: NotificationCenter
    let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    public init(fileURL: URL, notificationCenter: NotificationCenter = .default) {
        self.fileName = fileURL.lastPathComponent
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.trackedURL = fileURL
        self.notificationCenter = notificationCenter
    }

    public func start() {
        stop()
        query.searchScopes = [
            NSMetadataQueryUbiquitousDocumentsScope,
            NSMetadataQueryUbiquitousDataScope,
            directoryURL,
        ]

        // §2.5: scope to the tracked file — name AND containing directory.
        let directoryPath = directoryURL.standardizedFileURL.path
        query.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName),
            NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, directoryPath),
        ])

        let fire: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            // §2.5: batch result access. Without this the query keeps mutating its
            // result set while we walk it, and every incremental change posts
            // another notification.
            self.query.disableUpdates()
            let matched = self.matchesTrackedItem()
            self.query.enableUpdates()
            guard matched else { return }
            self.onChange?()
        }
        for name: NSNotification.Name in [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let token = notificationCenter.addObserver(
                forName: name, object: query, queue: nil, using: fire
            )
            observers.append(token)
        }

        if Thread.isMainThread {
            query.start()
        } else {
            DispatchQueue.main.async { [weak self] in self?.query.start() }
        }
    }

    /// Second line of defence behind the predicate: confirm at least one result is
    /// the file we actually track before waking the store.
    private func matchesTrackedItem() -> Bool {
        let target = trackedURL.standardizedFileURL.path
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem else { continue }
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
               URL(fileURLWithPath: path).standardizedFileURL.path == target {
                return true
            }
            if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
               url.standardizedFileURL.path == target {
                return true
            }
        }
        return false
    }

    public func stop() {
        for token in observers { notificationCenter.removeObserver(token) }
        observers.removeAll()
        query.stop()
    }

    deinit { stop() }
}
