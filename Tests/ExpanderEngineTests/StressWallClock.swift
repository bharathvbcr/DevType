import Foundation

/// Wall-clock budgets for stress "pathology detector" tests.
///
/// These bounds exist to catch algorithmic regressions (quadratic folds,
/// runaway nested-snippet rendering), never to measure absolute speed. Both
/// budgets sit far above healthy runtime on the slowest supported runner
/// (macos-14 / Xcode 15.4 CI — a seeded graph expansion measured 4.7 s there
/// against a former 2 s bound) and far below regressed runtime, so a loaded
/// machine cannot produce a false positive while a real blowup still fails
/// loudly. Deterministic invariants asserted alongside (output ceilings,
/// decode results) stay strict regardless.
enum StressWallClock {

    /// Calibrated canary whose regressed runtime is seconds-to-minutes scale;
    /// healthy runtime is sub-second even under CI load.
    static let quadraticCanary: TimeInterval = 10

    /// Coarse spin/termination guard around work that completes in ≤5 s on CI
    /// when healthy; matches the budget used by ImportStressTests.
    static let terminationGuard: TimeInterval = 30
}
