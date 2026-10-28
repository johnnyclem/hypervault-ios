import HyperVaultKit
import SwiftUI

/// What the Appearance pane holds: the theme the person's web dashboard wears, and the choice of another. The app does
/// not wear it (the stock look is the only one it draws), so the pane says it is about the website, and a change is
/// confirmed only once the server has agreed to it.
@MainActor
@Observable
final class AppearanceModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// What the profile holds, as the server last said it.
    private(set) var stored: String?
    private(set) var isSaving = false
    /// The sentence for a change the server agreed to; cleared when the next one starts.
    private(set) var confirmation: String?
    private(set) var problem: String?

    let choices: [DashboardThemeChoice]

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let rest: AccountRest
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let catalog: [Capabilities.ThemeInfo]

    init(client: HVClient, rest: AccountRest, userID: String, catalog: [Capabilities.ThemeInfo]) {
        self.client = client
        self.rest = rest
        self.userID = userID
        self.catalog = catalog
        choices = DashboardThemes.choices(from: catalog)
    }

    /// The choice the picker shows: an id the catalog does not list is the stock look, as on the web.
    var selection: String? { DashboardThemes.selection(stored: stored, in: catalog) }

    func load() async {
        do {
            stored = try await rest.dashboardTheme(userID: userID)
            phase = .loaded
        } catch {
            if phase != .loaded { phase = .failed(keysMessage(for: error)) }
        }
    }

    func choose(_ id: String?) async {
        guard !isSaving, id != selection else { return }
        isSaving = true
        problem = nil
        confirmation = nil
        defer { isSaving = false }
        do {
            let saved = try await client.send(.setDashboardTheme(id))
            stored = saved.theme
            let sentence = DashboardThemeCopy.confirmation(for: saved.theme, in: catalog)
            confirmation = sentence
            AccessibilityNotification.Announcement(sentence).post()
        } catch {
            let sentence = keysMessage(for: error)
            problem = sentence
            AccessibilityNotification.Announcement(sentence).post()
        }
    }
}

/// Appearance, a pane of the You tab. On the web it is one look for the dashboard and chat, and a look for each address.
/// Here it is the website's theme, in words that do not say the app changed; each address's look is under Domain.
struct AppearancePane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: AppearanceModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                HVLoadingState().frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .task {
            if model == nil {
                model = AppearanceModel(client: env.client, rest: env.keysRest, userID: env.user.id, catalog: env.capabilities.themes)
            }
            await model?.load()
        }
    }

    @ViewBuilder
    private func content(_ model: AppearanceModel) -> some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 2).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
                .frame(maxHeight: .infinity)
        case .loaded:
            list(model)
        }
    }

    private func list(_ model: AppearanceModel) -> some View {
        List {
            Section {
                Text(DashboardThemeCopy.line)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            }

            Section(
                header: HVSectionHeader(title: DashboardThemeCopy.sectionTitle),
                footer: Text(DashboardThemeCopy.footer)
            ) {
                Picker(DashboardThemeCopy.pickerLabel, selection: Binding(
                    get: { model.selection },
                    set: { id in Task { await model.choose(id) } }
                )) {
                    ForEach(model.choices, id: \.themeID) { choice in
                        Text(choice.label).tag(choice.themeID)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isSaving)
                .frame(minHeight: 44)
                .accessibilityIdentifier("appearance.theme")

                status(model)
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
    }

    /// What became of the last choice: working on it, the server's refusal, or the server's yes.
    @ViewBuilder
    private func status(_ model: AppearanceModel) -> some View {
        if model.isSaving {
            HStack(spacing: HV.Space.s) {
                ProgressView()
                Text(DashboardThemeCopy.saving).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if let problem = model.problem {
            KeysInlineMessage(text: problem)
                .accessibilityIdentifier("appearance.problem")
        } else if let confirmation = model.confirmation {
            Text(confirmation)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .accessibilityIdentifier("appearance.confirmation")
        }
    }
}
