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
                HVEmptyState(symbol: "globe", title: "This address is gone", actionTitle: "Back") { dismiss() }.frame(maxHeight: .infinity)
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
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                    Text("Serves your whole vault. Visitors see this address's look; you still get your dashboard.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
                Button {
                    webPage = KeysWebPage(claim.url)
                } label: {
                    Label("Visit \(claim.host)", systemImage: "safari")
                }
            }

            lookSection(claim, saving: saving)
            homeSection(claim, saving: saving)

            if let warning {
                Section { KeysNotice(text: warning, symbol: "lock.fill") }
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
                    Label("Preview the page", systemImage: "eye")
                }
            }
            if let gated = options.first(where: { $0.slug == home }), gated.isGated {
                Text("\u{1F512} That page is \(gated.visibility == "password" ? "password-gated" : "private"), so visitors to \(claim.host) get the lock page. Make it public to serve it here.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            HVSectionHeader(title: "Home page")
        } footer: {
            Text("Pick one of your pages and \(claim.host) opens straight to it, with nothing after the address.")
        }
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
    KeysPreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmDetailPreview() }
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
