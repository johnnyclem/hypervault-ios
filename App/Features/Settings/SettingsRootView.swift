import HyperVaultKit
import SwiftUI

/// Look, feel, security and the server. The things that belong to this phone
/// rather than to the account.
struct SettingsRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppEnvironment.self) private var env

    @AppStorage(PrefKey.appearance) private var appearance = AppearanceChoice.system
    @AppStorage(PrefKey.accent) private var accent = AccentChoice.blue
    @AppStorage(PrefKey.haptics) private var haptics = true
    @AppStorage(PrefKey.biometricLock) private var biometricLock = false
    @AppStorage(SpotlightIndexer.preferenceKey) private var spotlight = true

    @State private var waiting = OutboxStore.count
    @State private var serverText = ""
    @State private var isChangingServer = false
    @State private var serverError: String?
    @State private var showServerConfirm = false

    var body: some View {
        Form {
            Section(header: HVSectionHeader(title: "Look")) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text("Accent").font(.hvBody)
                    HStack(spacing: HV.Space.xs) {
                        ForEach(AccentChoice.allCases) { choice in
                            accentSwatch(choice)
                        }
                    }
                }
                .padding(.vertical, HV.Space.xs)
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Feel")) {
                Toggle("Haptics", isOn: $haptics)
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Search"), footer: Text("Find your pages and memories from your Home Screen. Names and short summaries are kept on this phone for search; keys are never included.")) {
                // Search is switched off while the lock is on; the choice comes back with it.
                Toggle("Show in Spotlight", isOn: Binding(get: { spotlight && !biometricLock }, set: { spotlight = $0 }))
                    .disabled(biometricLock)
                    .onChange(of: spotlight) { _, on in if !on { SpotlightIndexer.clear() } }
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Security"), footer: Text("Ask for \(model.lock.methodName) when you open HyperVault, and blank the app switcher. Your saved logins, cards and keys never leave the server, so there is nothing on this phone to unlock them. While the lock is on, widgets and Spotlight show nothing from your vault, and what you ask Siri to keep waits until you unlock the app.")) {
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

            Section(header: HVSectionHeader(title: "Account")) {
                LabeledContent("Signed in as", value: env.user.email ?? env.user.displayName ?? "You")
                LabeledContent("Server", value: env.server.baseURL.host() ?? env.server.baseURL.absoluteString)
                    .contextMenu {
                        Button("Copy address") { UIPasteboard.general.string = env.server.baseURL.absoluteString }
                    }
            }.hvListRow()

            Section(header: HVSectionHeader(title: "Advanced"), footer: advancedFooter) {
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
                Link("Read the privacy note", destination: env.webURL("/explain.md"))
            }.hvListRow()
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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

    private func accentSwatch(_ choice: AccentChoice) -> some View {
        Button {
            accent = choice
            Haptics.select()
        } label: {
            ZStack {
                Circle().fill(choice.color).frame(width: 34, height: 34)
                if accent == choice {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.background)
                }
            }
            .overlay(Circle().strokeBorder(Palette.textTertiary.opacity(0.4), lineWidth: accent == choice ? 0 : 1))
            .scaleEffect(accent == choice ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(accent == choice ? .isSelected : [])
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
