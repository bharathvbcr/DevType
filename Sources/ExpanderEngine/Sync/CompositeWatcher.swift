// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

public final class CompositeWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    private let children: [StoreWatching]

    public init(_ children: [StoreWatching]) {
        self.children = children
        for child in children {
            child.onChange = { [weak self] in self?.onChange?() }
        }
    }

    public func start() { children.forEach { $0.start() } }

    public func stop() { children.forEach { $0.stop() } }
}
