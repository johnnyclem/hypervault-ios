import Foundation

/// One line of a diff, ready to draw.
public struct ArtifactDiffLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case context, added, removed
        /// "@@ -1,3 +1,4 @@", or the gap where unchanged lines were folded.
        case hunk
        /// "\ No newline at end of file".
        case note
    }

    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public enum ArtifactDiffLines {
    /// Lines of the server's unified patch (`GET .../diff`), without the
    /// "Index:" and "---/+++" preamble.
    public static func parse(patch: String) -> [ArtifactDiffLine] {
        var lines: [ArtifactDiffLine] = []
        var inHunk = false
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                inHunk = true
                lines.append(ArtifactDiffLine(id: lines.count, kind: .hunk, text: line))
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                lines.append(ArtifactDiffLine(id: lines.count, kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                lines.append(ArtifactDiffLine(id: lines.count, kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix("\\") {
                lines.append(ArtifactDiffLine(id: lines.count, kind: .note, text: line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix(" ") {
                lines.append(ArtifactDiffLine(id: lines.count, kind: .context, text: String(line.dropFirst())))
            }
        }
        return lines
    }

    /// The most lines (both sides together) a local comparison will take on.
    public static let compareLimit = 6_000

    /// A line diff of two texts, for showing what keeping one side over the
    /// other changes. Nil when the texts are too long to compare on a phone.
    public static func compare(old: String, new: String, context: Int = 3) -> [ArtifactDiffLine]? {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        guard before.count + after.count <= compareLimit else { return nil }

        let difference = after.difference(from: before)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var full: [(ArtifactDiffLine.Kind, String)] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                full.append((.removed, before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                full.append((.added, after[j]))
                j += 1
            } else if i < before.count {
                full.append((.context, before[i]))
                i += 1
                j += 1
            } else {
                // Cannot happen for a consistent difference; keep going rather than loop.
                full.append((.added, after[j]))
                j += 1
            }
        }
        return fold(full, context: context)
    }

    /// Keeps `context` unchanged lines around each change and folds the rest
    /// into one "..." line, so a long file shows only what differs.
    static func fold(_ lines: [(ArtifactDiffLine.Kind, String)], context: Int) -> [ArtifactDiffLine] {
        var keep = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where line.0 != .context {
            let lower = max(0, index - context)
            let upper = min(lines.count - 1, index + context)
            for near in lower...upper { keep[near] = true }
        }
        var result: [ArtifactDiffLine] = []
        var folded = 0
        func flush() {
            guard folded > 0 else { return }
            result.append(ArtifactDiffLine(id: result.count, kind: .hunk, text: folded == 1 ? "1 unchanged line" : "\(folded) unchanged lines"))
            folded = 0
        }
        for (index, line) in lines.enumerated() {
            if keep[index] {
                flush()
                result.append(ArtifactDiffLine(id: result.count, kind: line.0, text: line.1))
            } else {
                folded += 1
            }
        }
        flush()
        return result
    }
}
