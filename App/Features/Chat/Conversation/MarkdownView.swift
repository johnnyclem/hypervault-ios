import HyperVaultKit
import SwiftUI
import UIKit

/// A reply, drawn: paragraphs, headings, lists, quotes, tables and code blocks
/// with a copy button. Text is selectable. The Kit decides the blocks
/// (`ChatMarkdown`); inline marks (bold, links, `code`) are the system's.
struct ChatMarkdownView: View {
    let text: String
    var font: Font = .hvBody

    var body: some View {
        let blocks = ChatMarkdownCache.blocks(for: text)
        VStack(alignment: .leading, spacing: HV.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ChatMarkdownBlockView(block: block, font: font)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Parsing a long reply on every redraw would make scrolling heavy.
enum ChatMarkdownCache {
    private final class Box {
        let blocks: [ChatMarkdownBlock]
        init(_ blocks: [ChatMarkdownBlock]) { self.blocks = blocks }
    }

    private static let storage: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 300
        return cache
    }()

    static func blocks(for text: String) -> [ChatMarkdownBlock] {
        // A reply that is still being written changes every moment: don't cache it by its text.
        let key = "\(text.count):\(text.hashValue)" as NSString
        if let box = storage.object(forKey: key) { return box.blocks }
        let parsed = ChatMarkdown.parse(text)
        storage.setObject(Box(parsed), forKey: key)
        return parsed
    }

    private static let inline: NSCache<NSString, NSAttributedStringBox> = {
        let cache = NSCache<NSString, NSAttributedStringBox>()
        cache.countLimit = 600
        return cache
    }()

    final class NSAttributedStringBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    static func attributed(_ text: String) -> AttributedString {
        let key = "\(text.count):\(text.hashValue)" as NSString
        if let box = inline.object(forKey: key) { return box.value }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // Inline code gets a quiet chip behind it.
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].backgroundColor = Palette.surfaceRaised
            }
        }
        inline.setObject(NSAttributedStringBox(result), forKey: key)
        return result
    }
}

struct ChatInlineText: View {
    let text: String
    var font: Font = .hvBody
    var color: Color = Palette.textPrimary

    var body: some View {
        Text(ChatMarkdownCache.attributed(text))
            .font(font)
            .foregroundStyle(color)
            .tint(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

struct ChatMarkdownBlockView: View {
    let block: ChatMarkdownBlock
    var font: Font = .hvBody

    var body: some View {
        switch block {
        case .paragraph(let text):
            ChatInlineText(text: text, font: font)
        case .heading(let level, let text):
            ChatInlineText(text: text, font: Self.headingFont(level))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, level <= 2 ? HV.Space.xxs : 0)
        case .code(let language, let code):
            ChatCodeBlockView(language: language, code: code)
        case .list(let items):
            VStack(alignment: .leading, spacing: HV.Space.hair) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ChatListItemView(item: item, font: font)
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: HV.Space.s) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.border).frame(width: 3)
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, nested in
                        ChatMarkdownBlockView(block: nested, font: font)
                    }
                }
                .foregroundStyle(Palette.textSecondary)
            }
        case .table(let header, let rows):
            ChatTableBlockView(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, HV.Space.xxs)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(.title2, weight: .semibold)
        case 2: return .system(.title3, weight: .semibold)
        case 3: return .system(.headline, weight: .semibold)
        default: return .system(.subheadline, weight: .semibold)
        }
    }
}

private struct ChatListItemView: View {
    let item: ChatMarkdownListItem
    var font: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
            if let checked = item.checked {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    // The text style of the item's words, so the glyph grows with them.
                    .font(font)
                    .foregroundStyle(checked ? Palette.mint : Palette.textTertiary)
                    .accessibilityLabel(checked ? "Done" : "Not done")
            } else {
                Text(item.marker)
                    .font(font)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 18, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            ChatInlineText(text: item.text, font: font)
        }
        .padding(.leading, CGFloat(item.depth) * HV.Space.m)
    }
}

private struct ChatTableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: HV.Space.m, verticalSpacing: HV.Space.xs) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(ChatMarkdownCache.attributed(cell)).font(.hvFootnote.weight(.semibold))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(ChatMarkdownCache.attributed(cell)).font(.hvFootnote)
                        }
                    }
                }
            }
            .padding(HV.Space.s)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

/// Code, with its language and a copy button. Long lines scroll sideways
/// rather than wrap, so code keeps its shape.
struct ChatCodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "code")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .textCase(.lowercase)
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? HVSymbol.copied : HVSymbol.copy)
                        .font(.hvCaption.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, HV.Space.xs)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Palette.mint : Palette.textSecondary)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.leading, HV.Space.s)
            .padding(.trailing, HV.Space.xxs)
            .frame(minHeight: 36)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.hvMono)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, HV.Space.s)
                    .padding(.bottom, HV.Space.s)
            }
        }
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func copy() {
        UIPasteboard.general.string = code
        Haptics.tap()
        HV.Motion.animate(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(HV.Motion.copiedHold * 1_000_000_000))
            HV.Motion.animate(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

#Preview("Markdown") {
    ScrollView {
        ChatMarkdownView(text: """
        # A plan

        Here is **the plan**, with `inline code` and a [link](https://hypervault.store).

        - one
        - two
          - nested

        ```swift
        let greeting = "Hello"
        print(greeting)
        ```

        > Quiet words.

        | Name | Qty |
        | --- | --- |
        | Apples | 3 |
        """)
        .padding()
    }
    .background(Palette.background)
}
