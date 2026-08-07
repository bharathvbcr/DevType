import XCTest
@testable import ExpanderEngine

/// Covers the Setup-wizard hardening: bounded identity subprocesses, the quit-then-reopen
/// relaunch helper, and the Input Monitoring advance rule.
final class SetupWizardHardeningTests: XCTestCase {

    // MARK: - BoundedProcess

    func testRunCapturesStdout() {
        let result = BoundedProcess.run(
            executable: "/bin/echo",
            arguments: ["hello"]
        )
        XCTAssertEqual(result?.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(result?.timedOut, false)
    }

    func testRunReportsNonZeroExitWithoutTimingOut() {
        let result = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "exit 3"]
        )
        XCTAssertEqual(result?.exitCode, 3)
        XCTAssertEqual(result?.timedOut, false)
    }

    func testRunReturnsNilWhenExecutableMissing() {
        XCTAssertNil(
            BoundedProcess.run(
                executable: "/usr/bin/definitely-not-a-real-tool-xyz",
                arguments: []
            )
        )
    }

    func testMergeStandardErrorCapturesStderr() {
        // `codesign -dvvv` writes its whole report to stderr; without merging, CDHash parsing
        // reads an empty string and every identity readout says "unavailable".
        let merged = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo oops 1>&2"],
            mergeStandardError: true
        )
        XCTAssertEqual(merged?.output.trimmingCharacters(in: .whitespacesAndNewlines), "oops")

        let unmerged = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo oops 1>&2"],
            mergeStandardError: false
        )
        XCTAssertEqual(unmerged?.output.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// Regression: `run()` → `waitUntilExit()` → `readDataToEndOfFile()` deadlocks once the child
    /// writes past the ~64KB pipe buffer, because nobody is draining while the parent waits.
    /// `mdfind` on a machine with many DevType copies is exactly that shape.
    func testRunDrainsOutputLargerThanThePipeBuffer() {
        let byteCount = 400_000
        let result = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/head -c \(byteCount) /dev/zero | /usr/bin/tr '\\0' 'x'"],
            timeout: 20
        )
        XCTAssertEqual(result?.timedOut, false)
        XCTAssertEqual(result?.output.count, byteCount)
    }

    /// A hung `codesign` must not be able to hang the caller — the wizard gates Finish on that
    /// load completing.
    func testRunTerminatesAtTheDeadline() {
        let started = Date()
        let result = BoundedProcess.run(
            executable: "/bin/sleep",
            arguments: ["30"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result?.timedOut, true)
        // Deadline plus the SIGTERM grace, with headroom for a loaded CI machine.
        XCTAssertLessThan(elapsed, 10.0, "bounded run should not wait for the child to finish")
    }

    /// SIGTERM is trapped and ignored, so only the SIGKILL escalation can end this.
    func testRunKillsAChildThatIgnoresSIGTERM() {
        let started = Date()
        let result = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30"],
            timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result?.timedOut, true)
        XCTAssertLessThan(elapsed, 10.0, "SIGKILL escalation should bound a SIGTERM-proof child")
    }

    // MARK: - AppRelauncher

    func testWaiterArgumentsShape() {
        let args = AppRelauncher.waiterArguments(pid: 4321, bundlePath: "/Applications/DevType.app")

        XCTAssertEqual(args.first, "-c")
        XCTAssertEqual(args[1], AppRelauncher.waiterScript)
        // Conventional `$0` placeholder — without it `$1` would be the bundle path, not the PID.
        XCTAssertEqual(args[2], "sh")
        XCTAssertEqual(args[3], "4321")
        XCTAssertEqual(args[4], "/Applications/DevType.app")
        XCTAssertEqual(args[5], AppRelauncher.pollInterval)
        XCTAssertEqual(args[6], AppRelauncher.settleDelay)
    }

    /// Values travel as positional parameters, never interpolated into the script, so a path with
    /// shell metacharacters reaches `open` verbatim instead of being re-parsed.
    func testWaiterArgumentsPassHostilePathsVerbatim() {
        let nasty = #"/Users/x/My "Apps"/$(whoami);rm -rf ~/DevType.app"#
        let args = AppRelauncher.waiterArguments(pid: 1, bundlePath: nasty)

        XCTAssertEqual(args[4], nasty)
        XCTAssertFalse(
            AppRelauncher.waiterScript.contains(nasty),
            "the path must never be baked into the script text"
        )
    }

    func testWaiterLoopIsBounded() {
        let args = AppRelauncher.waiterArguments(pid: 1, bundlePath: "/tmp/DevType.app")
        let iterations = Int(args[7]) ?? 0
        XCTAssertGreaterThan(iterations, 0)
        // Without a ceiling, a parent whose terminate is vetoed leaves an `sh` polling forever.
        let pollSeconds = Double(AppRelauncher.pollInterval) ?? 0.2
        XCTAssertEqual(
            Double(iterations) * pollSeconds,
            Double(AppRelauncher.maxWaitSeconds),
            accuracy: pollSeconds
        )
    }

    func testWaiterScriptIsValidShell() {
        // `sh -n` parses without executing. A syntax error here would mean Relaunch silently
        // spawns a helper that dies immediately and never reopens the app.
        let result = BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-n", "-c", AppRelauncher.waiterScript],
            mergeStandardError: true
        )
        XCTAssertEqual(result?.exitCode, 0, "waiter script failed to parse: \(result?.output ?? "")")
    }

    /// The waiter must survive its parent. Standing in a short-lived `sleep` for the app, the
    /// helper should still be running once that "parent" is gone.
    func testWaiterOutlivesTheProcessItWaitsOn() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["0.5"]
        try parent.run()
        let parentPID = parent.processIdentifier

        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-relaunch-\(parentPID).marker")
        try? FileManager.default.removeItem(at: marker)

        // Same wait-then-act structure as `waiterScript`, with `open` swapped for a marker file
        // so the test does not launch an application.
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            #"pid="$1"; out="$2"; while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done; echo done > "$out""#,
            "sh",
            String(parentPID),
            marker.path
        ]
        try waiter.run()

        parent.waitUntilExit()
        waiter.waitUntilExit()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "waiter should act only after the watched PID exits"
        )
        try? FileManager.default.removeItem(at: marker)
    }

    // MARK: - Input Monitoring advance rule

    func testCanAdvanceFromInputMonitoringWhenGranted() {
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromInputMonitoring(
                canListenTap: true,
                didAttemptRequest: false
            )
        )
    }

    /// Before the user has asked for it, the step still insists — Request is the whole point of
    /// that screen.
    func testCanAdvanceFromInputMonitoringBlocksBeforeAnyRequest() {
        XCTAssertFalse(
            ProcessIdentity.canAdvanceFromInputMonitoring(
                canListenTap: false,
                didAttemptRequest: false
            )
        )
    }

    /// Regression: a stale TCC record means Listen can never be granted. Gating hard on
    /// `canListenTap` trapped that user before Accessibility was even offered, so they could never
    /// Finish — while Verify and Done both treat a missing Listen as non-blocking.
    func testCanAdvanceFromInputMonitoringAfterAFailedRequest() {
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromInputMonitoring(
                canListenTap: false,
                didAttemptRequest: true
            )
        )
    }

    /// The three step gates must agree that Accessibility is the only hard requirement.
    func testListenIsNeverTheSoleReasonSetupCannotComplete() {
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromInputMonitoring(
                canListenTap: false,
                didAttemptRequest: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            )
        )
    }
}
