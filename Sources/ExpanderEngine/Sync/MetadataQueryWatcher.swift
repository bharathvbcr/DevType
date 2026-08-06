// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import AppKit
import Foundation

public final class MetadataQueryWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    private let fileName: String
    private let directoryURL: URL
    private let notificationCenter: NotificationCenter
    let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    public init(fileURL: URL, notificationCenter: NotificationCenter = .default) {
        self.fileName = fileURL.lastPathComponent
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.notificationCenter = notificationCenter
    }

    public func start() {
        stop()
        query.searchScopes = [
            NSMetadataQueryUbiquitousDocumentsScope,
            NSMetadataQueryUbiquitousDataScope,
            directoryURL,
        ]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)

        let fire: (Notification) -> Void = { [weak self] _ in self?.onChange?() }
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

    public func stop() {
        for token in observers { notificationCenter.removeObserver(token) }
        observers.removeAll()
        query.stop()
    }

    deinit { stop() }
}
