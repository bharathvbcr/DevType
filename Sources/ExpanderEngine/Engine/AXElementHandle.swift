import ApplicationServices

/// An `AXUIElement` carried inside a `Sendable` value.
///
/// `AXUIElement` is an immutable CF reference to an element in another process; every call on it
/// is IPC that the Accessibility API serves from any thread (the selection read runs on its own
/// queue for exactly that reason — see `SelectionReader`'s thread contract). The Swift overlay
/// does not mark it `Sendable`, so a value type that keeps one, such as a captured selection or
/// a probe candidate, would stop being `Sendable` under the Swift 6 language mode. This is the one
/// place that vouches for it, instead of each holder declaring itself `@unchecked`.
///
/// Equality is the element's own (`CFEqual`): two separately copied references to one element are
/// equal, references to different elements are not.
public struct AXElementHandle: @unchecked Sendable, Equatable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: AXElementHandle, rhs: AXElementHandle) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
