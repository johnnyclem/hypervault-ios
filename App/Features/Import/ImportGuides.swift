import HyperVaultKit
import SwiftUI

/// How to get an export out of each service, in plain steps. The menu names
/// are the web page's own (app/vault/import/page.tsx); the extra words say
/// where the file ends up on a phone.
struct ImportGuide {
    let symbol: String
    let tint: Color
    let headline: String
    let steps: [String]
    let footnote: String?

    static func guide(for platform: ImportPlatform) -> ImportGuide {
        switch platform {
        case .chatgpt:
            return ImportGuide(
                symbol: "bubble.left.and.bubble.right.fill", tint: Palette.mint,
                headline: "Get your ChatGPT export",
                steps: [
                    "In ChatGPT, open Settings.",
                    "Choose Data controls, then Export data.",
                    "Confirm. OpenAI emails you a download link, usually within minutes.",
                    "Open that email on this phone and download the zip. It lands in Files, in Downloads.",
                    "Come back here and choose the zip, or conversations.json from inside it.",
                ],
                footnote: "The link expires after a while, so download it soon."
            )
        case .claude:
            return ImportGuide(
                symbol: "sparkle", tint: Palette.coral,
                headline: "Get your Claude export",
                steps: [
                    "In Claude, open Settings, then Privacy.",
                    "Choose Export data.",
                    "Anthropic emails you a download link.",
                    "Download the zip on this phone.",
                    "Come back here and choose the zip, or conversations.json from inside it.",
                ],
                footnote: nil
            )
        case .gemini:
            return ImportGuide(
                symbol: "sparkles", tint: Palette.blue,
                headline: "Get your Gemini history",
                steps: [
                    "On this phone, open takeout.google.com in Safari and sign in.",
                    "Choose only My Activity, and include only Gemini Apps.",
                    "Pick JSON as the format, then create the export.",
                    "Download the zip when Google says it is ready.",
                    "Come back here and choose the zip, or MyActivity.json from inside it.",
                ],
                footnote: "Google's export is a log of what you asked and often leaves out the replies, so Gemini history arrives as one conversation per day."
            )
        case .grok:
            return ImportGuide(
                symbol: "bolt.fill", tint: Palette.violet,
                headline: "Get your Grok history",
                steps: [
                    "On x.com in Safari, open Settings.",
                    "Choose Download an archive of your data.",
                    "X prepares it and tells you when it is ready, which can take a day.",
                    "Download the zip and choose it here.",
                ],
                footnote: "The archive is large because of its images. HyperVault looks through it for the conversation file and leaves the images alone."
            )
        case .other:
            return ImportGuide(
                symbol: "doc.on.clipboard", tint: Palette.amber,
                headline: "Paste a conversation",
                steps: [
                    "Open the chat in the app and copy the conversation.",
                    "Paste it below.",
                    "Start each message with who said it, like “User:” and “Assistant:”, or “You:” and “Claude:”.",
                ],
                footnote: "Use this for apps that cannot export."
            )
        }
    }
}

extension ImportPlatform {
    /// What a person calls it on the choice card.
    var cardTitle: String { self == .other ? "Something else" : title }
    var cardSubtitle: String {
        switch self {
        case .chatgpt: return "OpenAI export"
        case .claude: return "Anthropic export"
        case .gemini: return "Google Takeout"
        case .grok: return "X archive"
        case .other: return "Paste text"
        }
    }

    var guide: ImportGuide { ImportGuide.guide(for: self) }
}
