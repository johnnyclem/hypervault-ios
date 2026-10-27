import Foundation

/// The vault section of the web's front door (`lib/copy.ts`, `LANDING_VAULT_*`), which the first-run story tells
/// word for word. The readers are the only agents the story may name as able to use a saved value: a chat app can
/// connect but cannot read one, so none is on the list, and a heading over it claims no more than that the agents come
/// from more than one company.
extension HVCopy {
    public static let landingVaultHeading = "Not tied to one AI company"
    public static let landingVaultSaveLine = "Save a login, a card, your contact info or an API key once."

    /// Who can read a saved value, one to a chip.
    public static let landingVaultReaders = ["Claude Code", "Codex", "Cursor", "Gemini CLI", "Grok Build", "your own script"]
    public static let landingVaultAgents = "Claude Code, Codex, Cursor, Gemini CLI, Grok Build or your own script"
    public static let landingVaultUseLine = "Your agents can use it, whether that is Claude Code, Codex, Cursor, Gemini CLI, Grok Build or your own script. Each one gets only what you allow."

    /// What is never shown again and, in the same breath, what stays visible.
    public static let landingVaultLockLine = "Passwords, card numbers, API keys and each full entry are encrypted when you save them and never shown again. Only the name you give each one and a short label, like a username, an email or a card's brand and last four digits, stay visible so you can tell them apart."
}
