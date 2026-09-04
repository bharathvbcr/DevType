import Foundation

/// Counter arithmetic that saturates instead of trapping.
///
/// Six private copies of this existed, across two modules, all serving one purpose: a
/// diagnostic or usage counter must never trap the process just because it ran long
/// enough to overflow. `saturatingAdd` in `DevLogMirror`, `AIDiagnosticsStore`,
/// `DiagnosticReport` and `VoiceDiagnosticsRecorder`; `addingClamped` in
/// `UsageStatsStore`, `InjectTelemetryLog` and `StatsViewController`;
/// `incrementClamped` and `saturatingIncrement` for the +1 case.
///
/// A namespace of free functions rather than `Int` extension methods, so the call shape
/// at all forty-odd sites is unchanged and the consolidation stays a rename.
public enum Saturating {
    /// `lhs + rhs`, pinned to `max` (or `min`) rather than trapping on overflow.
    ///
    /// Every copy this replaces returned `max` for *any* overflow, which is only right
    /// for a non-negative delta — the only kind any caller passes. Saturating toward the
    /// bound the sum actually ran past keeps that true for the callers there are, and
    /// correct for one that later passes a negative delta.
    public static func adding<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? T.max : T.min
    }

    /// `value + 1`, pinned to `max` rather than trapping.
    public static func incrementing<T: FixedWidthInteger>(_ value: T) -> T {
        adding(value, 1)
    }

    /// `lhs * rhs`, pinned to the bound the product ran past rather than trapping.
    public static func multiplying<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return product }
        return (lhs < 0) == (rhs < 0) ? T.max : T.min
    }
}
