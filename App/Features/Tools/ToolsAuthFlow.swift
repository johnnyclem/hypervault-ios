import AuthenticationServices
import HyperVaultKit
import SwiftUI

/// Opens a login page in the system's web sign-in sheet and says how it ended.
/// The callback scheme is `hypervault`; today the server's OAuth callback is a
/// page that closes itself rather than a redirect, so the sheet usually ends
/// with the person tapping Cancel, and the caller finds out whether the login
/// worked by asking the server (`ToolsModel.serverAfterLogin`).
@MainActor
final class ToolsWebAuth {
    enum Outcome {
        /// The server redirected to `hypervault://...`.
        case redirected(URL)
        /// The sheet closed without a redirect.
        case closed
    }

    private let presenter = WebAuthPresenter()
    private var session: ASWebAuthenticationSession?

    func run(_ url: URL) async throws -> Outcome {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "hypervault") { callback, error in
                if let callback {
                    continuation.resume(returning: .redirected(callback))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .closed)
                } else {
                    continuation.resume(throwing: HVError.invalidRequest(error?.localizedDescription ?? "The login did not open. Try again."))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: HVError.invalidRequest("The login did not open. Try again."))
            }
        }
    }
}

/// The server a login is for.
struct ToolsAuthTarget: Equatable {
    var url: String
    var name: String?
    var registryId: String?
    /// Set when signing in again to a server that is already connected.
    var existing: McpServer?

    var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return URL(string: url)?.host ?? url
    }
}

/// A server said it needs a login: this walks a person through it, with a
/// browser login first and a pasted token as the way out.
@MainActor
@Observable
final class ToolsAuthFlow {
    enum Mode { case choose, token }

    let target: ToolsAuthTarget
    var mode: Mode = .choose
    var headerName = "Authorization"
    var token = ""
    var saveToVault = false
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var note: String?

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let web = ToolsWebAuth()
    @ObservationIgnored private let model: ToolsModel

    init(target: ToolsAuthTarget, client: HVClient, model: ToolsModel) {
        self.target = target
        self.client = client
        self.model = model
    }

    var canSubmitToken: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking }

    /// Whether a pasted token is a way in. A server connected through a login keeps its login grant, and the
    /// grant's bearer is sent in place of any Authorization header, so a token pasted for it would be saved and
    /// never used. Signing in again, or removing the server and adding it with a token, are the ways in.
    var offersToken: Bool { target.existing?.authType != .oauth }

    static let loginGoneNote = "This service no longer offers sign-in on its page. Remove this server and add it again with a token."

    func useToken() {
        guard offersToken else { return }
        mode = .token
        error = nil
    }

    func backToChoice() {
        mode = .choose
        error = nil
    }

    /// Signs in through the browser. Returns the server once it is connected.
    func signIn() async -> McpServer? {
        guard !isWorking else { return nil }
        isWorking = true
        error = nil
        note = nil
        defer { isWorking = false }
        do {
            let request = McpOAuthStartRequest(
                url: target.url, name: target.name, registryId: target.registryId,
                serverId: target.existing?.id, saveToVault: saveToVault
            )
            let start = try await client.send(.startMcpOAuth(request))
            let outcome = try await web.run(start.authorizationUrl)
            if case .redirected(let callback) = outcome, case .failed(let message) = McpOAuthResult(callback: callback) {
                error = message
                return nil
            }
            if let server = await model.serverAfterLogin(url: target.url, previous: target.existing) {
                Haptics.success()
                return server
            }
            if case .closed = outcome {
                // Closed without a sign-in: say nothing loud, but say something.
                note = "That login did not finish. If the page asked you to sign in to HyperVault first, do that in Safari, then try again."
            } else {
                error = "The login did not finish. Try again."
            }
            return nil
        } catch let failure as HVError where failure.isMcpOAuthUnavailable {
            if offersToken {
                mode = .token
                note = failure.userMessage
            } else {
                note = Self.loginGoneNote
            }
            return nil
        } catch {
            self.error = (error as? HVError)?.userMessage ?? error.localizedDescription
            Haptics.failure()
            return nil
        }
    }

    /// Connects with a pasted token. Returns the server once it is connected.
    func submitToken() async -> McpServer? {
        guard canSubmitToken, let headers = McpAuthHeader.make(name: headerName, token: token) else { return nil }
        isWorking = true
        error = nil
        defer { isWorking = false }
        if let existing = target.existing {
            guard await model.replaceHeaders(serverID: existing.id, headers: headers) else { return nil }
            token = ""
            return model.server(id: existing.id)
        }
        do {
            let request = McpAddRequest(
                url: target.url, name: target.name, headers: headers,
                registryId: target.registryId, saveToVault: saveToVault
            )
            let answer = try await client.send(.addMcpServer(request))
            token = ""
            Haptics.success()
            model.didAdd(answer.server, message: answer.message)
            return answer.server
        } catch let failure as HVError where failure.isMcpAuthRequired {
            error = "That token was turned away. Check it and try again."
            Haptics.failure()
            return nil
        } catch {
            self.error = (error as? HVError)?.userMessage ?? error.localizedDescription
            Haptics.failure()
            return nil
        }
    }
}

/// "This server needs you to sign in": the browser login first, a pasted token if that is not on offer.
struct ToolsAuthChallengeView: View {
    @Bindable var flow: ToolsAuthFlow
    var onConnected: (McpServer) -> Void
    var onCancel: (() -> Void)?

    @FocusState private var tokenFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            header
            if let note = flow.note {
                Text(note).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            switch flow.mode {
            case .choose: chooser
            case .token: tokenForm
            }
            vaultToggle
            if let error = flow.error {
                Text(error)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.danger)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .hvCard()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            HVIconBadge(symbol: "lock.fill", tint: Palette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(flow.target.displayName) wants you to sign in")
                    .font(.hvHeadline)
                Text(flow.mode == .choose
                     ? "You will log in on the service's own page. HyperVault keeps the key it gets back, encrypted, and never shows it."
                     : "Paste the API key or token from the service. HyperVault keeps it encrypted and never shows it again.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: HV.Space.xs) {
            Button {
                Task { if let server = await flow.signIn() { onConnected(server) } }
            } label: {
                if flow.isWorking { ProgressView().tint(Palette.textSecondary) } else { Text("Sign in on the service's page") }
            }
            .buttonStyle(.hvPrimary)
            .disabled(flow.isWorking)

            // A ghost button carries its own side padding for the tap target; pulling the outer
            // ones back lets their words line up with the edges of the card's content.
            HStack {
                if flow.offersToken {
                    Button("Use a token instead") { flow.useToken() }
                        .buttonStyle(.hvGhost)
                        .padding(.leading, -HV.Space.s)
                        .disabled(flow.isWorking)
                }
                if let onCancel {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.hvGhost)
                        .padding(.trailing, -HV.Space.s)
                        .disabled(flow.isWorking)
                }
            }
        }
    }

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVLabeledField(title: "Header name") {
                TextField("Header name", text: $flow.headerName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            HVLabeledField(title: "API key or token") {
                SecureField("API key or token", text: $flow.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($tokenFocused)
                    .submitLabel(.go)
                    .onSubmit { submit() }
            }
            Button {
                submit()
            } label: {
                if flow.isWorking { ProgressView().tint(Palette.textSecondary) } else { Text(flow.target.existing == nil ? "Connect" : "Replace the token") }
            }
            .buttonStyle(.hvPrimary)
            .disabled(!flow.canSubmitToken)
            HStack {
                Button("Back") { flow.backToChoice() }
                    .buttonStyle(.hvGhost)
                    .padding(.leading, -HV.Space.s)
                    .disabled(flow.isWorking)
                if let onCancel {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.hvGhost)
                        .padding(.trailing, -HV.Space.s)
                        .disabled(flow.isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private var vaultToggle: some View {
        if flow.target.existing == nil {
            Toggle(isOn: $flow.saveToVault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save to the saved-secrets vault").font(.hvCallout)
                    Text("Keeps the key as a named secret you can manage under Vault, instead of only on this server.")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .disabled(flow.isWorking)
        }
    }

    private func submit() {
        guard flow.canSubmitToken else { return }
        Task { if let server = await flow.submitToken() { onConnected(server) } }
    }
}
