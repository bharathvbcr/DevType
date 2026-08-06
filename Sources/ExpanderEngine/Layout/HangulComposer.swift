// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Deterministic Hangul composition from physical QWERTY keys (two-set Korean).
public enum HangulComposer {

    private static let unshifted: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ",
        "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ",
        "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ",
        "n": "ㅜ", "m": "ㅡ",
    ]

    private static let shifted: [Character: Character] = [
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ",
        "O": "ㅒ", "P": "ㅖ",
    ]

    public static func jamo(for physical: Character) -> Character? {
        if let s = shifted[physical] { return s }
        let lowerString = physical.lowercased()
        guard lowerString.count == 1, let lower = lowerString.first else { return nil }
        return unshifted[lower]
    }

    private static let choseong: [Character] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ",
    ]
    private static let jungseong: [Character] = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅘ",
        "ㅙ", "ㅚ", "ㅛ", "ㅜ", "ㅝ", "ㅞ", "ㅟ", "ㅠ", "ㅡ", "ㅢ", "ㅣ",
    ]

    private static let choIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: choseong.enumerated().map { ($1, $0) })
    private static let jungIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: jungseong.enumerated().map { ($1, $0) })

    private static let simpleJong: [Character: Int] = [
        "ㄱ": 1, "ㄲ": 2, "ㄴ": 4, "ㄷ": 7, "ㄹ": 8, "ㅁ": 16, "ㅂ": 17, "ㅅ": 19,
        "ㅆ": 20, "ㅇ": 21, "ㅈ": 22, "ㅊ": 23, "ㅋ": 24, "ㅌ": 25, "ㅍ": 26, "ㅎ": 27,
    ]

    private static let compoundJung: [Int: [Character: Int]] = [
        8:  ["ㅏ": 9, "ㅐ": 10, "ㅣ": 11],
        13: ["ㅓ": 14, "ㅔ": 15, "ㅣ": 16],
        18: ["ㅣ": 19],
    ]

    private static let compoundJong: [Int: [Character: Int]] = [
        1:  ["ㅅ": 3],
        4:  ["ㅈ": 5, "ㅎ": 6],
        8:  ["ㄱ": 9, "ㅁ": 10, "ㅂ": 11, "ㅅ": 12, "ㅌ": 13, "ㅍ": 14, "ㅎ": 15],
        17: ["ㅅ": 18],
    ]

    private static let jongDecompose: [Int: (remaining: Int, stolen: Character)] = [
        1: (0, "ㄱ"), 2: (0, "ㄲ"), 4: (0, "ㄴ"), 7: (0, "ㄷ"), 8: (0, "ㄹ"), 16: (0, "ㅁ"),
        17: (0, "ㅂ"), 19: (0, "ㅅ"), 20: (0, "ㅆ"), 21: (0, "ㅇ"), 22: (0, "ㅈ"), 23: (0, "ㅊ"),
        24: (0, "ㅋ"), 25: (0, "ㅌ"), 26: (0, "ㅍ"), 27: (0, "ㅎ"),
        3: (1, "ㅅ"), 5: (4, "ㅈ"), 6: (4, "ㅎ"), 9: (8, "ㄱ"), 10: (8, "ㅁ"), 11: (8, "ㅂ"),
        12: (8, "ㅅ"), 13: (8, "ㅌ"), 14: (8, "ㅍ"), 15: (8, "ㅎ"), 18: (17, "ㅅ"),
    ]

    public static func compose(physicalKeys: [Character]) -> String {
        var automaton = Automaton()
        for key in physicalKeys { automaton.feed(key) }
        automaton.finish()
        return automaton.output
    }

    public static func glyphCount(physicalKeys: [Character]) -> Int {
        compose(physicalKeys: physicalKeys).count
    }

    private struct Automaton {
        private(set) var output = ""
        private var cho: Int?
        private var jung: Int?
        private var jong: Int?

        private func rendered() -> String {
            if let cho, let jung {
                let code = 0xAC00 + ((cho * 21) + jung) * 28 + (jong ?? 0)
                guard let scalar = Unicode.Scalar(code) else { return "" }
                return String(scalar)
            }
            if let cho { return String(HangulComposer.choseong[cho]) }
            if let jung { return String(HangulComposer.jungseong[jung]) }
            return ""
        }

        private mutating func flush() {
            output += rendered()
            cho = nil
            jung = nil
            jong = nil
        }

        mutating func feed(_ key: Character) {
            guard let j = HangulComposer.jamo(for: key) else {
                flush()
                output.append(key)
                return
            }
            if let v = HangulComposer.jungIndex[j] {
                feedVowel(v)
            } else if let c = HangulComposer.choIndex[j] {
                feedConsonant(j, choIndexOf: c)
            } else {
                flush()
            }
        }

        mutating func finish() { flush() }

        private mutating func feedVowel(_ v: Int) {
            let vowel = HangulComposer.jungseong[v]

            if cho != nil, let curJung = jung, jong == nil,
               let combined = HangulComposer.compoundJung[curJung]?[vowel] {
                jung = combined
                return
            }

            if cho != nil, jung != nil, let curJong = jong {
                let decomposed = HangulComposer.jongDecompose[curJong] ?? (0, HangulComposer.choseong[0])
                jong = decomposed.remaining == 0 ? nil : decomposed.remaining
                output += rendered()
                cho = HangulComposer.choIndex[decomposed.stolen]
                jung = v
                jong = nil
                return
            }

            if cho != nil, jung == nil {
                jung = v
                return
            }

            if cho == nil, let curJung = jung, jong == nil,
               let combined = HangulComposer.compoundJung[curJung]?[vowel] {
                jung = combined
                return
            }

            flush()
            jung = v
        }

        private mutating func feedConsonant(_ j: Character, choIndexOf c: Int) {
            if cho != nil, jung != nil, jong == nil {
                if let ji = HangulComposer.simpleJong[j] {
                    jong = ji
                } else {
                    flush()
                    cho = c
                }
                return
            }

            if let curJong = jong {
                if let combined = HangulComposer.compoundJong[curJong]?[j] {
                    jong = combined
                } else {
                    flush()
                    cho = c
                }
                return
            }

            flush()
            cho = c
        }
    }
}
