import HyperVaultKit
import SwiftUI

/// Appearance, a pane of Settings. On the web it is one look for the dashboard and chat, and a look for each address.
/// Here it is the account's theme, which the website and this app wear (the phone can keep the app out of it); each
/// address's look is under Domain.
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
                model = AppearanceModel(client: env.client, loader: env.styleLoader, style: env.style, catalog: env.capabilities.themes)
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
                footer: Text(DashboardThemeCopy.footer).hvSectionNote()
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
                .disabled(model.isSaving || model.isOffline)
                .frame(minHeight: 44)
                .accessibilityIdentifier("appearance.theme")

                if model.selection != nil {
                    Button {
                        Task { await model.choose(nil) }
                    } label: {
                        Text(DashboardThemeCopy.resetRow).font(.hvBody)
                    }
                    .disabled(model.isSaving || model.isOffline)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("appearance.reset")
                }

                if let kit = model.style.state?.kit {
                    ThemePreview(kit: kit)
                        .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
                }

                status(model)
            }
            .hvListRow()

            Section(
                header: HVSectionHeader(title: DashboardThemeCopy.inAppTitle),
                footer: Text(DashboardThemeCopy.inAppFooter).hvSectionNote()
            ) {
                Toggle(DashboardThemeCopy.inAppToggle, isOn: Binding(
                    get: { model.style.appliesToApp },
                    set: { model.style.setAppliesToApp($0) }
                ))
                .accessibilityIdentifier("appearance.applyToApp")

                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    Text(model.wearingLine)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("appearance.wearing")
                    if let adjusted = model.adjustedLine {
                        Text(adjusted)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityIdentifier("appearance.adjusted")
                    }
                }
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
    }

    /// What became of the last choice: working on it, the server's refusal, the server's yes (and the way back from it), or
    /// that the server cannot be reached.
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
            NoteWithAction(
                text: confirmation, textIdentifier: "appearance.confirmation",
                actionTitle: model.undo == nil ? nil : DashboardThemeCopy.undo, actionIdentifier: "appearance.undo"
            ) { Task { await model.undoLastChange() } }
        }
        if model.isOffline {
            NoteWithAction(
                text: DashboardThemeCopy.offline, textIdentifier: "appearance.offline",
                actionTitle: "Try again", actionIdentifier: "appearance.retry"
            ) { Task { await model.load() } }
        }
    }
}

/// A line of small print with a button beside it, or under it where the two do not fit on a line (a long sentence, a large
/// text size).
private struct NoteWithAction: View {
    let text: String
    let textIdentifier: String
    let actionTitle: String?
    let actionIdentifier: String
    let action: () -> Void

    var body: some View {
        if let actionTitle {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.s) {
                    note
                    Spacer(minLength: 0)
                    button(actionTitle)
                }
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    note
                    button(actionTitle)
                }
            }
        } else {
            note
        }
    }

    private var note: some View {
        Text(text)
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(textIdentifier)
    }

    private func button(_ title: String) -> some View {
        Button(title, action: action)
            .buttonStyle(.hvGhost)
            .accessibilityIdentifier(actionIdentifier)
    }
}

/// The picked theme as it looks, drawn from the kit's own colours and not through `Palette`, so it shows the theme whether
/// or not the app is wearing it (the phone's switch may be off, or the app may not have changed over yet). Decorative: the
/// words under it say what is worn.
private struct ThemePreview: View {
    let kit: StyleKit

    var body: some View {
        let colors = kit.colors
        let inner = CGFloat(kit.radiusXL)
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(kit.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color(rgb: colors.foreground))
            Text("Secondary text")
                .font(.hvFootnote)
                .foregroundStyle(Color(rgb: colors.mutedForeground))
            HStack(spacing: HV.Space.s) {
                Text("Button")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Color(rgb: colors.actionForeground))
                    .padding(.horizontal, HV.Space.s)
                    .padding(.vertical, HV.Space.xxs)
                    .background(Color(rgb: colors.action), in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
                Text("Link")
                    .font(.hvFootnote)
                    .foregroundStyle(Color(rgb: colors.primary))
                Text("Accent")
                    .font(.hvFootnote)
                    .foregroundStyle(Color(rgb: colors.accent))
            }
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(rgb: colors.card), in: RoundedRectangle(cornerRadius: inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: inner, style: .continuous).strokeBorder(Color(rgb: colors.border).opacity(0.6), lineWidth: 1))
        .padding(HV.Space.s)
        .background(Color(rgb: colors.background), in: RoundedRectangle(cornerRadius: CGFloat(kit.radius2XL), style: .continuous))
        .fontDesign(kit.font.swiftUIDesign)
        .accessibilityHidden(true)
    }
}
