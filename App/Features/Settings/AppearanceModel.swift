import HyperVaultKit
import SwiftUI

/// What the Appearance pane holds: the theme the person's account wears, the choice of another, and what this phone does
/// with it. The theme is the web dashboard's (`profiles.theme`); the server derives an accessible look for it, and the app
/// wears that look (`StyleKitStore`) unless this phone's switch says not to.
///
/// A change is confirmed only once the server has agreed to it, and the look it answers with is worn at once, so the pane
/// itself re-themes: that is the preview. With no connection the pane shows the theme the phone kept and says so; the look
/// already worn is not touched, and changing the theme needs a connection.
@MainActor
@Observable
final class AppearanceModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The choice the last change replaced, offered back as Undo until the next one.
    struct Undo: Equatable {
        let themeID: String?
    }

    private(set) var phase: Phase = .loading
    /// What the profile holds, as the server last said it (or the phone kept it, offline).
    private(set) var stored: String?
    private(set) var isSaving = false
    /// The sentence for a change the server agreed to; cleared when the next one starts.
    private(set) var confirmation: String?
    private(set) var problem: String?
    /// The server could not be reached: what is shown is what the phone kept.
    private(set) var isOffline = false
    private(set) var undo: Undo?

    let choices: [DashboardThemeChoice]
    let style: StyleKitStore

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let loader: StyleKitLoader
    @ObservationIgnored private let catalog: [Capabilities.ThemeInfo]

    init(client: HVClient, loader: StyleKitLoader, style: StyleKitStore, catalog: [Capabilities.ThemeInfo]) {
        self.client = client
        self.loader = loader
        self.style = style
        self.catalog = catalog
        choices = DashboardThemes.choices(from: catalog)
    }

    /// The choice the picker shows: an id the catalog does not list is the stock look, as on the web.
    var selection: String? { DashboardThemes.selection(stored: stored, in: catalog) }

    /// What the app is wearing, in a sentence, and whether the server moved a colour to make it readable.
    var wearingLine: String {
        switch style.look {
        case .standard: return DashboardThemeCopy.wearingDefault
        case .worn(let name, _): return DashboardThemeCopy.wearing(name)
        case .off: return DashboardThemeCopy.off
        case .withheld(let themeID): return DashboardThemeCopy.cannotShow(DashboardThemes.name(of: themeID, in: catalog) ?? themeID)
        }
    }

    var adjustedLine: String? {
        if case .worn(_, true) = style.look { return DashboardThemeCopy.adjusted }
        return nil
    }

    func load() async {
        do {
            try await style.refresh(using: loader)
            stored = style.state?.theme
            isOffline = false
            problem = nil
            phase = .loaded
        } catch {
            if phase == .loaded {
                // A second look at a pane that is showing (Try again): what it shows stays, and the failure is said. A server
                // that answers with an error is not an absent one, so it is the error that is shown and not the offline note.
                isOffline = Self.isOffline(error)
                if !isOffline { problem = keysMessage(for: error) }
                return
            }
            if style.state != nil {
                // The phone kept the look it has; show that, and say the server could not be reached.
                stored = style.state?.theme
                isOffline = Self.isOffline(error)
                if !isOffline { problem = keysMessage(for: error) }
                phase = .loaded
            } else {
                phase = .failed(keysMessage(for: error))
            }
        }
    }

    func choose(_ id: String?) async {
        await change(to: id, isUndo: false)
    }

    /// Puts the choice the last change replaced back.
    func undoLastChange() async {
        guard let undo else { return }
        await change(to: undo.themeID, isUndo: true)
    }

    private func change(to id: String?, isUndo: Bool) async {
        guard !isSaving, !isOffline, id != selection else { return }
        let before = stored
        isSaving = true
        problem = nil
        confirmation = nil
        defer { isSaving = false }
        let mark = style.sessionMark
        do {
            let saved = try await client.send(.setDashboardTheme(id))
            stored = saved.theme
            undo = isUndo ? nil : Undo(themeID: before)
            // The answer carries the look the server derived for the choice, so it is worn now, without another request. If the
            // session ended while the server was answering, the answer is the old account's: nothing of it is worn, kept or said.
            guard await style.keep(saved.state, using: loader, since: mark) else { return }
            let sentence = DashboardThemeCopy.confirmation(for: saved.theme, in: catalog, inApp: style.look.isWorn)
            confirmation = sentence
            AccessibilityNotification.Announcement(sentence).post()
        } catch {
            let sentence = keysMessage(for: error)
            problem = sentence
            AccessibilityNotification.Announcement(sentence).post()
        }
    }

    private static func isOffline(_ error: Error) -> Bool {
        if case .transport = error as? HVError { return true }
        return false
    }
}
