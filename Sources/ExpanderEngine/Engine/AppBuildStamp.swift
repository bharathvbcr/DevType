import AppKit
import Foundation

/// Resolves another application's build string, cached for this process.
///
/// Exists so `AXWriteCapabilityStore` can tell "this app's AX is broken" apart from "this app's
/// AX *was* broken, three versions ago". A learned verdict is a claim about a specific build of
/// someone else's code; carrying it across an update states more than was ever observed.
///
/// Cheap by construction: the lookup is a running-application property when the app is running
/// and an `Info.plist` read otherwise, and either way the answer is memoised for the life of the
/// process. A miss is cached as well — an app that cannot be located will not be located on the
/// next keystroke either, and the caller treats "unknown build" as "do not retire the verdict".
public final class AppBuildStamp {
    public static let shared = AppBuildStamp()

    private let lock = UnfairLock()
    /// `.some(nil)` records a resolved miss, so a failing lookup is attempted once per process.
    private var cache: [String: String?] = [:]

    public init() {}

    /// `CFBundleVersion` for `bundleID`, or nil when the app cannot be located or says nothing.
    public func build(forBundleID bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.readBuild(bundleID: bundleID)
        lock.lock()
        cache[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    /// Drops the memo. For tests, and for a future "the user just updated an app" signal.
    public func invalidate() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func readBuild(bundleID: String) -> String? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let url = running.first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let url, let bundle = Bundle(url: url) else { return nil }
        // CFBundleVersion is the build; it moves on every release where CFBundleShortVersionString
        // may not. Fall back to the marketing version rather than giving up.
        let info = bundle.infoDictionary
        let build = info?["CFBundleVersion"] as? String
        let short = info?["CFBundleShortVersionString"] as? String
        let stamp = [short, build].compactMap { $0 }.joined(separator: "-")
        return stamp.isEmpty ? nil : stamp
    }
}
