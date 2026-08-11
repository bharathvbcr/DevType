import Foundation

/// Deterministic RNG — a randomised test must reproduce exactly when it fails, from the seed alone.
///
/// Shared by every fuzz/property test in this target. Conforms to `RandomNumberGenerator` so it
/// works both by hand (`rng.next()`) and with the stdlib's `using:` overloads
/// (`array.randomElement(using: &rng)`).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
