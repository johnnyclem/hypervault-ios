import HyperVaultKit
import SwiftUI

/// One claimed address: its look, the page it opens to, and a way to visit it. Both settings save the moment
/// they change, and go back if the server says no (components/theme-switcher.tsx).
struct RealmDetailView: View {
    let claimID: String
    let model: RealmsModel

    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var webPage: KeysWebPage?
    @State private var warning: String?

    var body: some View {
        Group {
            if let claim = model.claim(id: claimID) {
                details(claim)
            } else {
                HVEmptyState(symbol: HVSymbol.domain, title: "This address is gone", actionTitle: "Back") { dismiss() }.frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Address")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webPage) { page in KeysSafariSheet(url: page.url).ignoresSafeArea() }
    }

    private func details(_ claim: RealmClaim) -> some View {
        let saving = model.saving.contains(claim.id)
        return List {
            Section {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text(claim.host)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("Serves your whole vault. Visitors see this address's look; you still get your dashboard.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    webPage = KeysWebPage(claim.url)
                } label: {
                    // On one line, a little smaller if it must be, like the address above it: wrapped at a large text size
                    // the address was broken with a hyphen ("nova.vault.-/cool").
                    Label("Visit \(claim.host)", systemImage: "safari")
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .truncationMode(.middle)
                }
            }
            .hvListRow()

            lookSection(claim, saving: saving)
            homeSection(claim, saving: saving)

            if let warning {
                // The notice carries its own tint and border, so it sits on the page and not on a paper row.
                Section { KeysNotice(text: warning, symbol: "lock.fill") }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Look

    @ViewBuilder
    private func lookSection(_ claim: RealmClaim, saving: Bool) -> some View {
        let themes = env.capabilities.themes
        if !themes.isEmpty {
            Section {
                Picker("Look", selection: Binding(
                    get: { claim.theme ?? "" },
                    set: { setTheme(claim, $0.isEmpty ? nil : $0) }
                )) {
                    Text("\(claim.baseDomain) default").tag("")
                    ForEach(themes) { theme in
                        Text("\(theme.name) (\(theme.mode))").tag(theme.id)
                    }
                }
                .pickerStyle(.navigationLink)
                .disabled(saving)
            } header: {
                HVSectionHeader(title: "Look")
            } footer: {
                Text("Every address can wear its own. Changes show on the next visit.")
            }
            .hvListRow()
        }
    }

    // MARK: Home page

    @ViewBuilder
    private func homeSection(_ claim: RealmClaim, saving: Bool) -> some View {
        let home = claim.defaultArtifactSlug ?? ""
        // A home page the list does not know (saved long ago, older than the recent window) still has to be selectable.
        let options = home.isEmpty || model.snapshot.homeOptions.contains(where: { $0.slug == home })
            ? model.snapshot.homeOptions
            : [RealmHomeOption(slug: home, title: home)] + model.snapshot.homeOptions
        Section {
            Picker("Opens with", selection: Binding(
                get: { home },
                set: { setHome(claim, $0.isEmpty ? nil : $0) }
            )) {
                Text("Your vault index (default)").tag("")
                ForEach(options) { option in
                    Text(option.isGated ? "\(option.title) (\(option.visibility ?? "private"))" : option.title).tag(option.slug)
                }
            }
            .pickerStyle(.navigationLink)
            .disabled(saving)

            if !home.isEmpty {
                Button {
                    webPage = KeysWebPage(env.artifactURL(slug: home))
                } label: {
                    Label("Preview the page", systemImage: "eye").hvRowLabel()
                }
            }
            if let gated = options.first(where: { $0.slug == home }), gated.isGated {
                Label(
                    "That page is \(gated.visibility == "password" ? "password-gated" : "private"), so visitors to \(claim.host) get the lock page. Make it public to serve it here.",
                    systemImage: "lock.fill"
                )
                .hvRowLabel()
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            HVSectionHeader(title: "Home page")
        } footer: {
            Text("Pick one of your pages and \(claim.host) opens straight to it, with nothing after the address.")
        }
        .hvListRow()
    }

    // MARK: Saving

    private func setTheme(_ claim: RealmClaim, _ theme: String?) {
        guard theme != claim.theme else { return }
        Task {
            do {
                try await model.setTheme(claim, to: theme)
                Haptics.success()
                app.toasts.success("Saved.")
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func setHome(_ claim: RealmClaim, _ slug: String?) {
        guard slug != claim.defaultArtifactSlug else { return }
        warning = nil
        Task {
            do {
                let answer = try await model.setHome(claim, to: slug)
                warning = answer.warning
                Haptics.success()
                app.toasts.success("Saved.")
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

#if DEBUG
#Preview("Address") {
    PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmDetailPreview() }
}

private struct RealmDetailPreview: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: RealmsModel?

    var body: some View {
        Group {
            if let model { RealmDetailView(claimID: "c1", model: model) } else { HVLoadingState() }
        }
        .task {
            let loaded = RealmsModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id)
            await loaded.load()
            model = loaded
        }
    }
}
#endif
