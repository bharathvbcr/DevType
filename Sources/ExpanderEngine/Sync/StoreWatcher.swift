// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

public protocol StoreWatching: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

public final class DirectoryWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "devtype.store.watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func start() {
        stop()
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.onChange?() }
        src.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
