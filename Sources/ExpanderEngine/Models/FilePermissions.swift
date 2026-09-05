import Foundation

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
}
