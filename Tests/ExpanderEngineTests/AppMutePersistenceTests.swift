import XCTest
@testable import ExpanderEngine

// §-audit hardening for `AppMuteStore` persistence.
//
// The in-memory mutation happened under the lock but the disk write ran outside
// it on whatever thread called mute/unmute, so two writers could persist out of
// order and an older snapshot could win the file. Persistence now runs on a
// private serial queue, enqueued while the lock is held, so the disk write order
// equals the mutation order — last write wins.
//
// Harness note: the racing writers are dedicated `Thread`s (not
// `DispatchQueue.concurrentPerform`, whose pool width can serialize iterations in
// waves) with a start gate and an arrival barrier, so all eight final mutations
// genuinely contend.

final class AppMutePersistenceTests: XCTestCase {

    /// Hammer mute/unmute from several threads, then require the persisted file to
    /// converge to exactly the final in-memory state.
    func testConcurrentMuteUnmutePersistsFinalInMemoryState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeMuteRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("muted-apps.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AppMuteStore(fileURL: url)
        // Widen the snapshot→disk gap with a *randomized* delay so concurrent
        // writers genuinely overlap and completion order decouples from mutation
        // order; writes stay real so on-disk assertions remain meaningful.
        // (Kept short: post-fix these runs serialize on the persistence queue.)
        store.persistOverride = { ids, url in
            Thread.sleep(forTimeInterval: Double.random(in: 0...0.03))
            Self.writeToDisk(ids, fileURL: url)
        }

        // Every worker hammers ONE shared id with equal mutes and unmutes (net zero
        // for the final set) and finishes by muting an id only it touches. The
        // final in-memory set is therefore exactly the exclusive ids, no matter how
        // the operations interleave — so if an older snapshot's write lands after a
        // newer one's, the file visibly disagrees with memory.
        let exclusive = (0..<8).map { "com.race.final.worker\($0)" }
        let workerCount = exclusive.count

        let startGate = DispatchSemaphore(value: 0)
        let barrierLock = NSLock()
        var arrivedAtBarrier = 0
        let allDone = DispatchGroup()

        let threads = (0..<workerCount).map { worker -> Thread in
            allDone.enter()
            return Thread {
                defer { allDone.leave() }
                startGate.wait()
                for _ in 0..<6 {
                    store.mute("com.race.churn")
                    store.unmute("com.race.churn")
                }
                // Barrier: hold every worker here so the eight exclusive-id enders
                // mutate within microseconds of each other. Completion order is then
                // decided by the randomized persist delays, not mutation time —
                // exactly the reordering the serial persistence queue prevents.
                barrierLock.lock()
                arrivedAtBarrier += 1
                barrierLock.unlock()
                while true {
                    barrierLock.lock()
                    let everyone = arrivedAtBarrier == workerCount
                    barrierLock.unlock()
                    if everyone { break }
                    Thread.sleep(forTimeInterval: 0.0005)
                }
                store.mute(exclusive[worker])
            }
        }
        threads.forEach { $0.start() }
        for _ in 0..<workerCount { startGate.signal() }
        allDone.wait()

        let expected = store.allMuted()
        XCTAssertEqual(expected, exclusive.sorted())

        // Quiescence: poll until the file matches the final in-memory state (the
        // serial persistence queue may still be draining), then require the file
        // to stay there — a straggler write from a stale snapshot must not land
        // after the match.
        var persisted: [String]?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let raw = try? Data(contentsOf: url),
               let list = try? JSONDecoder().decode([String].self, from: raw) {
                persisted = list
                if list == expected { break }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        Thread.sleep(forTimeInterval: 0.4)
        if let raw = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([String].self, from: raw) {
            persisted = list
        }

        XCTAssertEqual(
            persisted, expected,
            "persisted file must match the final in-memory state — a stale writer won "
                + "the file. Expected \(expected.count) entries ending in the worker "
                + "finals, got \(String(describing: persisted?.count))"
        )
    }

    /// Mirrors the production write so the seam test exercises real file bytes.
    private static func writeToDisk(_ ids: Set<String>, fileURL: URL) {
        do {
            let data = try JSONEncoder().encode(ids.sorted())
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to save muted apps: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
