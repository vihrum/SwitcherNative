import Foundation

public struct KeyMapping {

    // MARK: - EN → UA (Apple Ukrainian PC layout)
    public static let enToUaMap: [Character: Character] = [
        // Lowercase
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н", "u": "г",
        "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ї", "a": "ф", "s": "і",
        "d": "в", "f": "а", "g": "п", "h": "р", "j": "о", "k": "л", "l": "д",
        ";": "ж", "'": "є", "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и",
        "n": "т", "m": "ь", ",": "б", ".": "ю", "/": ".", "`": "'", "\\": "ґ",
        // Uppercase
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н", "U": "Г",
        "I": "Ш", "O": "Щ", "P": "З", "{": "Х", "}": "Ї", "A": "Ф", "S": "І",
        "D": "В", "F": "А", "G": "П", "H": "Р", "J": "О", "K": "Л", "L": "Д",
        ":": "Ж", "\"": "Є", "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И",
        "N": "Т", "M": "Ь", "<": "Б", ">": "Ю", "?": ",", "~": "Ґ", "|": "Ґ"
    ]

    // MARK: - UA → EN (inverted + Russian Option-key symbols)
    public static let uaToEnMap: [Character: Character] = {
        var map = [Character: Character]()
        // Invert main table
        for (en, ua) in enToUaMap {
            map[ua] = en
        }
        // Russian letters accessible via Option in Apple Ukrainian layout
        map["ы"] = "s";  map["Ы"] = "S"
        map["э"] = "'";  map["Э"] = "\""
        map["ъ"] = "]";  map["Ъ"] = "}"
        map["ё"] = "`";  map["Ё"] = "~"
        return map
    }()

    // MARK: - Conversion

    public static func enToUa(_ text: String) -> String {
        String(text.map { enToUaMap[$0] ?? $0 })
    }

    public static func uaToEn(_ text: String) -> String {
        String(text.map { uaToEnMap[$0] ?? $0 })
    }

    // MARK: - Script detection

    /// Returns true if ALL letters in text are Latin (ASCII letters or known EN→UA keys)
    public static func isLatin(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0.isLetter ? $0.isASCII : true }
    }

    /// Returns true if text contains at least one Cyrillic character
    public static func isCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
