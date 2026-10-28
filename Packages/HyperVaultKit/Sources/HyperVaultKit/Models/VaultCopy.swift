import Foundation

// The sentences the Vault screens say, word for word. Two sources: the web's `lib/copy.ts` (the rename card, the
// lines for a change that did not go through, the loading line) and the handoff, which quotes the vault
// components' own strings that `lib/copy.ts` does not hold (sections 4.6, 4.7 and 5.10). Each is pinned by
// VaultCopyTests against that text. `HVError.userMessage` is not touched: other screens, and their tests, say
// its network sentence.

/// The Vault screens' own words.
public enum VaultCopy {
    // MARK: Rename (lib/copy.ts:302-326; handoff 5.13)

    /// The button, `RENAME_LABEL`.
    public static let renameLabel = "Rename"

    /// The label of the new-name field, `renameFieldLabel`.
    public static func renameFieldLabel(_ title: String) -> String {
        "New name for \(title)"
    }

    /// The one thing a rename costs, said where the new name is typed, `RENAME_WARNING`.
    public static let renameWarning = "Agents that ask for the old name will stop finding it."

    /// The rule under the rename field, `RENAME_HINT`. The add form's hint is `VaultItems.nameHint` instead.
    public static let renameHint = "Use 1 to 100 letters, digits, dots, dashes or underscores."

    // MARK: A change, or a load, that did not go through (lib/copy.ts:112,329-330; handoff 4.9)

    /// `KEY_CHANGE_FAILED_LINE`: a change the server did not explain.
    public static let keyChangeFailedLine = "That did not go through. Try again."

    /// `KEY_CHANGE_OFFLINE_LINE`: a change that never got there. The vault components say "Network hiccup — try
    /// again."; the handoff proposes this ASCII line, which `lib/copy.ts` already holds.
    public static let keyChangeOfflineLine = "Network hiccup. That did not go through. Try again."

    /// `YOURS_LOADING_LINE`, for the first load, which the web does not have (it renders the list on the server).
    public static let loadingLine = "Loading..."

    // MARK: The detail sheet (handoff 4.6, 4.7, 5.10)

    /// The label of the date the entry was made on; the date itself is in the medium style.
    public static let createdLabel = "Created"

    /// What the sheet says in the Last used row when no agent has read the entry.
    public static let sheetNeverUsedLine = "Never"

    /// What the sheet says about the value.
    public static let valueNeverShownLine = "The value is encrypted and never shown again."

    public static let allowedKeysHeading = "Allowed keys"
    public static let allowedKeysLine = "Only the agent keys switched on here can read it."

    /// With no agent keys at all (handoff 4.6: "the web's line").
    public static let noAgentKeysLine = "No agent keys yet. Generate one under Agent keys, then allow it here."

    public static let howAgentReadsHeading = "How an agent reads it"
    public static let allowedKeyGetsLine = "An allowed key gets back { name, kind, value }."

    /// For a login, card or contact; `fields` is `VaultItems.valueFieldsLine(_:)`.
    public static func jsonValueLine(fields: String) -> String {
        "The value is JSON with \(fields); empty fields are left out."
    }

    /// For a key, an MCP header or an OAuth grant.
    public static let exactValueLine = "The value is exactly what you saved."

    /// The message of the delete confirmation (handoff 4.7).
    public static let deleteConfirmationMessage = "Deleting it cuts off every agent at once."

    // MARK: Last used (handoff 5.10)

    /// The row's line: "Never used", or "Last used" and the ago line with its first letter lowercased ("Last used
    /// 2 days ago", "Last used just now", "Last used yesterday"). The detail sheet says `sheetLastUsedLine`.
    public static func rowLastUsedLine(_ lastAccessedAt: Date?, now: Date = Date()) -> String {
        guard let lastAccessedAt else { return AccountWords.neverUsed }
        return rowLastUsedLine(ago: agoLine(since: lastAccessedAt, now: now))
    }

    /// "Last used" and `ago` (one of `agoLine`'s lines) lower-cased.
    public static func rowLastUsedLine(ago: String) -> String {
        "Last used " + ago.lowercased()
    }

    /// The detail sheet's Last used value: "Never", or the ago line as it is ("2 days ago", "Just now").
    public static func sheetLastUsedLine(_ lastAccessedAt: Date?, now: Date = Date()) -> String {
        guard let lastAccessedAt else { return sheetNeverUsedLine }
        return agoLine(since: lastAccessedAt, now: now)
    }

    /// `AccountWords.agoLine` for the time since `date`. The gap is capped at a thousand billion seconds before it is
    /// divided into minutes, since `Int(Double.infinity)` traps, and nothing past that is a different answer.
    private static func agoLine(since date: Date, now: Date) -> String {
        AccountWords.agoLine(seconds: min(now.timeIntervalSince(date), 1.0e12))
    }
}

/// The sentence for an error from a vault call: the server's own words, which it writes for a person, with the
/// two exceptions the handoff makes (5.12, 8.2). A 404 "No such grant." is never shown, since the word on screen is
/// revoke, not grant. A network failure is the product's line for it and not `HVError.userMessage`'s.
public enum VaultErrorText {
    /// For a call that changed something (create, rename, delete, allow, revoke).
    public static func message(for error: Error) -> String {
        text(for: error, offline: VaultCopy.keyChangeOfflineLine, fallback: VaultCopy.keyChangeFailedLine)
    }

    /// For a call that only read (the list, a sheet's allowed keys).
    public static func loadMessage(for error: Error) -> String {
        text(for: error, offline: HVCopy.yoursOfflineLine, fallback: HVCopy.yoursFailedLine)
    }

    /// Whether `sentence` is the server's "No such grant.", which no screen shows.
    public static func isNoSuchGrant(_ sentence: String) -> Bool {
        VaultItems.jsTrim(sentence).lowercased().contains("no such grant")
    }

    private static func text(for error: Error, offline: String, fallback: String) -> String {
        guard let hv = error as? HVError else { return fallback }
        let sentence: String
        switch hv {
        case .transport: return offline
        case .api(let failure): sentence = failure.plainMessage
        default: sentence = hv.userMessage
        }
        return isNoSuchGrant(sentence) ? fallback : sentence
    }
}
