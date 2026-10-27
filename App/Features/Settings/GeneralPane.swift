import HyperVaultKit
import SwiftUI

/// General, the first pane of the You tab: the account you are signed in with (its email, its plan, signing out), and
/// under "On this phone" the things that belong to this phone rather than to the account: feel, search, the lock, what
/// is waiting to be kept, the server and the version.
struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @AppStorage(PrefKey.haptics) private var haptics = true
    @AppStorage(PrefKey.biometricLock) private var biometricLock = false
    @AppStorage(SpotlightIndexer.preferenceKey) private var spotlight = true

    /// The person's plan. Nil until the profile has been read, and when it cannot be: nothing is claimed about a plan
    /// that was not read.
    @State private var plan: AccountProfile?
    @State private var waiting = OutboxStore.count
    @State private var serverText = ""
    @State private var isChangingServer = false
    @State private var serverError: String?
    @State private var showServerConfirm = false

    var body: some View {
        Form {
            Section {
                Text(AccountPane.general.descriptionLine)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            }

            Section {
                profileCard
                LabeledContent("Email") {
                    Text(env.user.email ?? "No email on file")
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .truncationMode(.middle)
                }
                .accessibilityIdentifier("general.email")
                planRow
                SignOutButton(identifier: "you.signOut", detail: "Sign out on this device.")
            }.hvListRow()

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("On this phone")
                        .font(.hvTitle3)
                        .accessibilityAddTraits(.isHeader)
                    Text("These belong to this phone, not to your account.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.m, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            }

            Section(header: HVSectionHeader(title: "Feel")) {
                Toggle("Haptics", isOn: $haptics)
                    .accessibilityIdentifier("settings.haptics")
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Search"), footer: Text("Find your pages and memories from your Home Screen. Names and short summaries are kept on this phone for search; keys are never included.")) {
                // Search is switched off while the lock is on; the choice comes back with it.
                Toggle("Show in Spotlight", isOn: Binding(get: { spotlight && !biometricLock }, set: { spotlight = $0 }))
                    .accessibilityIdentifier("settings.spotlight")
                    .disabled(biometricLock)
                    .onChange(of: spotlight) { _, on in if !on { SpotlightIndexer.clear() } }
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Security"), footer: Text("Ask for \(model.lock.methodName) when you open HyperVault, and blank the app switcher. This is a lock on the screen, and your device passcode opens it too. The value of a saved login, card or key is never sent to this phone; its name and short label are. While the lock is on, widgets and Spotlight show nothing from your vault, and what you ask Siri to keep waits until you unlock the app.")) {
                Toggle("Lock with \(model.lock.methodName)", isOn: Binding(
                    get: { biometricLock },
                    set: { wanted in
                        Task {
                            if await model.lock.confirmChange() { biometricLock = wanted }
                        }
                    }
                ))
                .onChange(of: biometricLock) { _, on in model.lock.preferenceChanged(to: on) }
            }.hvListRow()

            if waiting > 0 {
                Section(header: HVSectionHeader(title: "Waiting"), footer: Text("Things you shared while there was no connection. They are kept the next time HyperVault can reach the server.")) {
                    LabeledContent("Waiting to keep", value: "\(waiting)")
                    Button("Try now") {
                        Task {
                            await env.flushOutbox(toasts: model.toasts)
                            waiting = OutboxStore.count
                        }
                    }
                }
            }

            Section(header: HVSectionHeader(title: "Advanced"), footer: advancedFooter) {
                LabeledContent("Server", value: env.server.baseURL.host() ?? env.server.baseURL.absoluteString)
                    .contextMenu {
                        Button("Copy address") { UIPasteboard.general.string = env.server.baseURL.absoluteString }
                    }
                TextField("Server address", text: $serverText, prompt: .hvPrompt("hypervault.store"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: serverText) { serverError = nil }
                Button {
                    showServerConfirm = true
                } label: {
                    if isChangingServer {
                        HStack(spacing: HV.Space.s) {
                            ProgressView()
                            Text("Checking the address")
                        }
                    } else {
                        Text("Use this server")
                    }
                }
                .disabled(!canSwitchServer || isChangingServer)
            }.hvListRow()

            Section(header: HVSectionHeader(title: "About")) {
                LabeledContent("Version", value: versionText)
                Link("Open hypervault.store", destination: env.server.baseURL)
                Link("How HyperVault works", destination: env.webURL("/explain.md"))
            }.hvListRow()
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .task { plan = try? await env.keysRest.profile(userID: env.user.id) }
        .confirmationDialog("Switch server?", isPresented: $showServerConfirm, titleVisibility: .visible) {
            Button("Switch and sign out", role: .destructive) {
                guard let config = ServerConfig(userInput: serverText) else { return }
                isChangingServer = true
                serverError = nil
                Task {
                    defer { isChangingServer = false }
                    do {
                        try await model.changeServer(to: config)
                    } catch {
                        let message = error.localizedDescription
                        serverError = message
                        AccessibilityNotification.Announcement(message).post()
                    }
                }
            }
        } message: {
            Text("You will be signed out and the app will start over against \(ServerConfig(userInput: serverText)?.baseURL.host() ?? "the new server").")
        }
    }

    /// A new address that is well formed and is not the one already in use.
    private var canSwitchServer: Bool {
        guard let candidate = ServerConfig(userInput: serverText) else { return false }
        return candidate != env.server
    }

    private var advancedFooter: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("Only change this to use your own HyperVault deployment. The address is checked first, then you are signed out.")
            if let serverError {
                Text(serverError).foregroundStyle(Palette.danger)
            }
        }
    }

    /// The avatar and the name. The address is on the Email row below.
    private var profileCard: some View {
        // Beside the name while it has the room; at an accessibility size the avatar would leave it a narrow column.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HV.Space.s))
            : AnyLayout(HStackLayout(spacing: HV.Space.m))
        return layout {
            HVAvatar(
                name: env.user.displayName ?? env.user.email ?? "?",
                imageURL: env.user.avatarUrl.flatMap(URL.init(string:)),
                size: 56
            )
            Text(env.user.displayName ?? env.user.firstName ?? "You")
                .font(.hvTitle3)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HV.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("you.profile")
    }

    /// Pro or Free, and for Free what Pro gets you. No price and no way to buy: payment is on the website.
    private var planRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plan").font(.hvBody)
                if let plan, !plan.isPro {
                    Text("Pro gets you an address of your own, like you.vault.cool.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: HV.Space.xs)
            if let plan {
                if plan.isPro { HVTag(text: "Pro", tint: Palette.blue) } else { HVTag(text: "Free") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("general.plan")
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
