import Foundation

// How the vault list orders its rows. The web sorts by name with `Intl.Collator("en", { sensitivity: "base" })`
// (components/vault-pane/vault-pane.tsx:40): case and accents do not count, so "Github" and "github" tie and
// keep the order the API gave them (oldest first), and "a10" sorts before "a2" because digits are not read as
// numbers. `localizedCaseInsensitiveCompare` is not that: it follows the device's language (a Danish phone puts
// "aa" after "z"), it counts accents, it has no tie-break, and Linux and Apple platforms bundle different ICU
// versions. This comparator reads the name over Unicode scalars and nothing else, so every device gives the order
// the server's collator gives.
//
// A secret's name is `[A-Za-z0-9._-]`, so what is exact is ASCII: ICU orders `_` < `-` < `.` < digits < letters,
// a letter's two cases equal, a shorter name before a longer one it begins. Names from before the rule may hold
// other letters; the Latin-1 and Latin Extended-A letters are folded to their base letters as ICU folds them at
// this strength (é is e, ß is ss, ø is o, æ is ae) and combining marks count for nothing. Any other letter sorts
// after Latin, in code point order. That part is best effort.

/// The fixed English name order of the vault list.
public enum VaultNameOrder {
    /// -1, 0 or 1 for `a` before, equal to or after `b`. Equal means the collator cannot tell them apart ("Github"
    /// and "github"); `sorted` keeps such names in the order it was given.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = sortKey(a)
        let right = sortKey(b)
        if left == right { return .orderedSame }
        return left.lexicographicallyPrecedes(right) ? .orderedAscending : .orderedDescending
    }

    /// `items` ordered by `name`, with names the collator ties left in their input order (JavaScript's sort is
    /// stable, and Swift's is not documented to be).
    public static func sorted<Element>(_ items: [Element], by name: (Element) -> String) -> [Element] {
        let keyed = items.enumerated().map { (offset: $0.offset, key: sortKey(name($0.element)), item: $0.element) }
        let ordered = keyed.sorted { left, right in
            if left.key == right.key { return left.offset < right.offset }
            return left.key.lexicographicallyPrecedes(right.key)
        }
        return ordered.map { $0.item }
    }

    /// Two names compare as their keys do. One weight per base character; ignorable scalars have none.
    public static func sortKey(_ name: String) -> [Int] {
        var key: [Int] = []
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if value < 0x80 {
                if let weight = asciiWeight(value) { key.append(weight) }
            } else if (0x0300...0x036F).contains(value) {
                continue  // a combining mark: nothing at this strength
            } else if value == 0x131 {
                key.append(dotlessI)  // the Turkish dotless i is a letter of its own, right after i
            } else if let base = folds[value] {
                for baseValue in base { if let weight = asciiWeight(baseValue) { key.append(weight) } }
            } else {
                for lower in scalar.properties.lowercaseMapping.unicodeScalars { key.append(otherLetters + Int(lower.value)) }
            }
        }
        return key
    }

    // MARK: Weights

    /// ASCII that is not a letter or a digit, in ICU's order (space, then `_ - , ; : ! ? . ' " ( ) [ ] { } @ * / \ & # % ` ^ + < = > | ~ $`).
    private static let symbols: [UInt32] = Array(" _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".unicodeScalars.map { $0.value })
    private static let digitsStart = 100
    private static let lettersStart = 200
    private static let otherLetters = 1000
    private static let dotlessI = lettersStart + 8 * 10 + 5

    private static func asciiWeight(_ value: UInt32) -> Int? {
        switch value {
        case 0x30...0x39: return digitsStart + Int(value - 0x30)
        case 0x41...0x5A: return lettersStart + Int(value - 0x41) * 10
        case 0x61...0x7A: return lettersStart + Int(value - 0x61) * 10
        default:
            // Controls (below space, and DEL) are ignorable to ICU.
            guard let index = symbols.firstIndex(of: value) else { return nil }
            return 1 + index
        }
    }

    /// The Latin-1 Supplement and Latin Extended-A letters ICU treats as a base letter (or two) at this strength.
    /// Generated from `Intl.Collator("en", { sensitivity: "base" })` in Node 22; thorn, eng, kra and the like have
    /// no base letter and are left out.
    private static let foldGroups: [(base: String, letters: String)] = [
        ("a", "ªÀÁÂÃÄÅàáâãäåĀāĂăĄą"),
        ("ae", "Ææ"),
        ("c", "ÇçĆćĈĉĊċČč"),
        ("d", "ÐðĎďĐđ"),
        ("e", "ÈÉÊËèéêëĒēĔĕĖėĘęĚě"),
        ("g", "ĜĝĞğĠġĢģ"),
        ("h", "ĤĥĦħ"),
        ("i", "ÌÍÎÏìíîïĨĩĪīĬĭĮįİ"),
        ("ij", "Ĳĳ"),
        ("j", "Ĵĵ"),
        ("k", "Ķķ"),
        ("l", "ĹĺĻļĽľĿŀŁł"),
        ("n", "ÑñŃńŅņŇň"),
        ("o", "ºÒÓÔÕÖØòóôõöøŌōŎŏŐő"),
        ("oe", "Œœ"),
        ("r", "ŔŕŖŗŘř"),
        ("s", "ŚśŜŝŞşŠšſ"),
        ("ss", "ß"),
        ("t", "ŢţŤť"),
        ("u", "ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲų"),
        ("w", "Ŵŵ"),
        ("y", "ÝýÿŶŷŸ"),
        ("z", "ŹźŻżŽž"),
    ]

    private static let folds: [UInt32: [UInt32]] = {
        var table: [UInt32: [UInt32]] = [:]
        for group in foldGroups {
            let base = group.base.unicodeScalars.map { $0.value }
            for scalar in group.letters.unicodeScalars { table[scalar.value] = base }
        }
        return table
    }()
}

extension Array where Element == VaultSecret {
    /// The rows in the order the web's vault list shows them (`VaultNameOrder`), ties kept in the order they are in.
    public func sortedByName() -> [VaultSecret] {
        VaultNameOrder.sorted(self, by: { $0.name })
    }
}
