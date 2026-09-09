import Foundation
import Darwin

/// POSIX mode changes for the files DevType writes on the user's behalf.
///
/// `DebugTrace` and `VoiceDiagnosticsRecorder` each carried a byte-identical private copy,
/// and both use it the same way: as the default for an injected `permissionSetter`, so a
/// test can make the mode change fail and prove the writer refuses to retain content at a
/// path whose owner-only mode it could not verify.
public enum FilePermissions {
    public static func setPOSIX(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    /// Publish a complete owner-only file with one rename. Unique staging names permit
    /// independent store instances to write without sharing or removing each other's temp file.
    /// The prior destination survives every failure before publication.
    static func atomicWrite(
        _ data: Data,
        to destination: URL,
        beforePublish: (() throws -> Void)? = nil
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var closed = false
        var published = false
        defer {
            if !closed {
                do { try handle.close() }
                catch { DevTypeLog.store.error("Atomic writer close failed \(DevTypeLog.errorMetadata(error), privacy: .public)") }
            }
            if !published, unlink(temporary.path) != 0, errno != ENOENT {
                DevTypeLog.store.error("Atomic writer staging cleanup failed errno=\(errno, privacy: .public)")
            }
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        closed = true
        try beforePublish?()
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        published = true
    }
}
