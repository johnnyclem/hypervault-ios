import Foundation

/// The words of the Vault screens that are the app's own: the web has no sheet to copy them from (a native confirm
/// instead of a silent drop, a name rule for the path an agent calls). Every other sentence is the web's, and lives
/// in the Kit (`VaultCopy`, `VaultErrorText`, `HVCopy`), pinned there against the web's text.
///
/// Copy for the owner: the strings marked so below are proposals the handoff leaves open.
enum VaultScreenCopy {
    static let closeLabel = "Close"
    /// The add form's own Back, which stands in for the system's while something is typed.
    static let backLabel = "Back"

    // MARK: Add

    static let addTitle = "Add to your vault"
    static let chooseLine = "What would you like to save?"
    static let saveLabel = "Save"
    static let savingLabel = "Saving..."
    static let replaceLabel = "Replace"
    static let replacingLabel = "Replacing..."

    /// Under Save: what the sheet does with the value.
    static let afterSaveLine = "Once saved, the value cannot be shown again. You can replace it."

    /// Shown when a Close would drop what was typed (copy for the owner: the web drops it without asking).
    static let discardTitle = "Discard what you typed?"
    static let discardMessage = "Nothing has been saved yet."
    static let discardLabel = "Discard"
    static let keepEditingLabel = "Keep editing"

    /// "." and ".." follow the server's name rule but cannot be addressed as a path segment (copy for the owner).
    static let dotsOnlyName = "A name cannot be just dots."

    // MARK: The list

    /// The empty Vault pane (`components/vault-pane/vault-pane.tsx:27`, brand book section 5.3): said in the dashed box.
    static let emptyVaultLine = "Nothing saved yet. Add a login, a card or contact info, then choose which agents may use it."

    // MARK: The entry

    static let connectAnAgentLabel = "Connect an agent"
    static let tryAgainLabel = "Try again"
    static let copyLabel = "Copy"
    static let copyFetchCommandLabel = "Copy fetch command"
    static let copiedLabel = "Copied"
    static let savingSwitchValue = "Saving"
}
