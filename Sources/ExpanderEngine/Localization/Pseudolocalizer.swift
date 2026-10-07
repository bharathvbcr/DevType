import Foundation

/// Pseudolocalization for layout checks: every UI string comes out accented, bracketed and about
/// 40% longer, so truncation, clipping, hard-coded English and concatenated fragments are visible
/// without a translation.
///
/// Turn it on for one launch with either
///
///     DEVTYPE_PSEUDOLOCALE=1 swift run DevType
///     open .build/DevType.app --args -devtype.debug.pseudolocale YES
///
/// or persistently with `defaults write com.devtype.app devtype.debug.pseudolocale -bool YES`.
///
/// Format specifiers (`%@`, `%d`, `%1$@`, `%.1f`, `%lld`, `%%`, …) are copied through untouched and
/// in order, so `String(format:arguments:)` consumes exactly the arguments the source string does.
public enum Pseudolocalizer {
    public static let defaultsKey = "devtype.debug.pseudolocale"
    public static let environmentKey = "DEVTYPE_PSEUDOLOCALE"

    /// Whether the current process asked for pseudolocalized strings.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let value = environment[environmentKey] {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return defaults.bool(forKey: defaultsKey)
    }

    /// Growth applied on top of the accented text, as a fraction of its letter count.
    static let expansion = 0.4

    public static func transform(_ source: String) -> String {
        guard !source.isEmpty else { return source }
        var output = ""
        var letters = 0
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "%", let end = formatSpecifierEnd(in: source, from: index) {
                output += source[index..<end]
                index = end
                continue
            }
            let character = source[index]
            if let accented = accents[character] {
                output.append(accented)
                letters += 1
            } else {
                output.append(character)
                if character.isLetter { letters += 1 }
            }
            index = source.index(after: index)
        }
        let padding = Int((Double(max(letters, 1)) * expansion).rounded(.up))
        return "[" + output + " " + String(repeating: "~", count: padding) + "]"
    }

    /// End of the printf-style specifier starting at `start` (which holds `%`), or nil when the
    /// `%` does not begin a specifier `String(format:)` would consume.
    static func formatSpecifierEnd(in string: String, from start: String.Index) -> String.Index? {
        let tail = string[start...]
        guard let match = tail.prefixMatch(of: specifier) else { return nil }
        return match.range.upperBound
    }

    // Position (`1$`), flags, width, precision, length modifier, conversion.
    private static let specifier = #/%(?:\d+\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]/#

    private static let accents: [Character: Character] = [
        "a": "á", "b": "ƀ", "c": "ç", "d": "ð", "e": "é", "f": "ƒ", "g": "ĝ", "h": "ĥ", "i": "í",
        "j": "ĵ", "k": "ķ", "l": "ļ", "m": "ɱ", "n": "ñ", "o": "ó", "p": "þ", "q": "ǫ", "r": "ŕ",
        "s": "š", "t": "ţ", "u": "ú", "v": "ṽ", "w": "ŵ", "x": "ẋ", "y": "ý", "z": "ž",
        "A": "Á", "B": "Ɓ", "C": "Ç", "D": "Ð", "E": "É", "F": "Ƒ", "G": "Ĝ", "H": "Ĥ", "I": "Í",
        "J": "Ĵ", "K": "Ķ", "L": "Ļ", "M": "Ṁ", "N": "Ñ", "O": "Ó", "P": "Þ", "Q": "Ǫ", "R": "Ŕ",
        "S": "Š", "T": "Ţ", "U": "Ú", "V": "Ṽ", "W": "Ŵ", "X": "Ẋ", "Y": "Ý", "Z": "Ž"
    ]
}
