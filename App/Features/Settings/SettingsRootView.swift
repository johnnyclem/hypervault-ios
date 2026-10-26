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
    @State private var showServerConfirm = false

    var body: some View {
        Form {
            Section(header: Text("Look")) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text("Accent").font(.hvBody)
                    HStack(spacing: HV.Space.m) {
                        ForEach(AccentChoice.allCases) { choice in
                            accentSwatch(choice)
                        }
                    }
                }
                .padding(.vertical, HV.Space.xs)
            }

            Section(header: Text("Feel")) {
                Toggle("Haptics", isOn: $haptics)
            }

            Section(header: Text("Search"), footer: Text("Find your pages and memories from your Home Screen. Names and short summaries are kept on this phone for search; keys are never included.")) {
                Toggle("Show in Spotlight", isOn: $spotlight)
                    .onChange(of: spotlight) { _, on in if !on { SpotlightIndexer.clear() } }
            }

            Section(header: Text("Security"), footer: Text("Ask for \(model.lock.methodName) when you open HyperVault, and blank the app switcher. Your saved logins, cards and keys never leave the server, so there is nothing on this phone to unlock them.")) {
                Toggle("Lock with \(model.lock.methodName)", isOn: Binding(
                    get: { biometricLock },
                    set: { wanted in
                        Task {
                            if await model.lock.confirmChange() { biometricLock = wanted }
                        }
                    }
                ))
            }

            if waiting > 0 {
                Section(header: Text("Waiting"), footer: Text("Things you shared while there was no connection. They are kept the next time HyperVault can reach the server.")) {
                    LabeledContent("Waiting to keep", value: "\(waiting)")
                    Button("Try now") {
                        Task {
                            await env.flushOutbox(toasts: model.toasts)
                            waiting = OutboxStore.count
                        }
                    }
                }
            }

            Section(header: Text("Account")) {
                LabeledContent("Signed in as", value: env.user.email ?? env.user.displayName ?? "You")
                LabeledContent("Server", value: env.server.baseURL.host() ?? env.server.baseURL.absoluteString)
                    .contextMenu {
                        Button("Copy address") { UIPasteboard.general.string = env.server.baseURL.absoluteString }
                    }
            }

            Section(header: Text("Advanced"), footer: Text("Only change this to use your own HyperVault deployment. Changing it signs you out.")) {
                TextField("hypervault.store", text: $serverText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Use this server") { showServerConfirm = true }
                    .disabled(ServerConfig(userInput: serverText) == nil || isChangingServer)
            }

            Section(header: Text("About")) {
                LabeledContent("Version", value: versionText)
                Link("Open hypervault.store", destination: env.server.baseURL)
                Link("Read the privacy note", destination: env.webURL("/explain.md"))
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Switch server?", isPresented: $showServerConfirm, titleVisibility: .visible) {
            Button("Switch and sign out", role: .destructive) {
                guard let config = ServerConfig(userInput: serverText) else { return }
                isChangingServer = true
                Task {
                    await model.changeServer(to: config)
                    isChangingServer = false
                }
            }
        } message: {
            Text("You will be signed out and the app will start over against \(ServerConfig(userInput: serverText)?.baseURL.host() ?? "the new server").")
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
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
            }
            .overlay(Circle().strokeBorder(Palette.border, lineWidth: accent == choice ? 0 : 1))
            .scaleEffect(accent == choice ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: accent)
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
