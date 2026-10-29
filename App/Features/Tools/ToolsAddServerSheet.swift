import HyperVaultKit
import SwiftUI

/// A server a person has picked but not yet connected: from the catalog, or
/// typed in.
struct ToolsCandidate: Identifiable, Equatable {
    var url: String
    var name: String?
    var registryId: String?
    var transport: String?

    var id: String { url }

    init(url: String = "", name: String? = nil, registryId: String? = nil, transport: String? = nil) {
        self.url = url
        self.name = name
        self.registryId = registryId
        self.transport = transport
    }

    init(_ entry: McpRegistryEntry) {
        self.init(url: entry.url, name: entry.name, registryId: entry.registryId, transport: entry.transport)
    }
}

/// Connecting a server, in steps: the address, a look at what it offers, then
/// the connection itself (with a login on the way if the server wants one).
@MainActor
@Observable
final class ToolsAddFlow {
    struct HeaderRow: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    enum Stage {
        case form
        case working(String)
        case preview(McpPreview)
        case needsSignIn
    }

    private(set) var stage: Stage = .form
    private(set) var error: String?
    private(set) var authFlow: ToolsAuthFlow?

    var url: String
    var name: String
    var headers: [HeaderRow] = []
    var saveToVault = false
    let registryId: String?
    let transport: String?
    let startsWithPreview: Bool

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let model: ToolsModel

    init(candidate: ToolsCandidate?, client: HVClient, model: ToolsModel) {
        self.client = client
        self.model = model
        url = candidate?.url ?? ""
        name = candidate?.name ?? ""
        registryId = candidate?.registryId
        transport = candidate?.transport
        startsWithPreview = candidate != nil
    }

    var isWorking: Bool {
        if case .working = stage { return true }
        return false
    }

    var hasHeaders: Bool { !typedHeaders.isEmpty }

    private var typedHeaders: [String: String] {
        var result: [String: String] = [:]
        for row in headers {
            let key = row.name.trimmingCharacters(in: .whitespaces)
            let value = row.value.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    private var cleanName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Steps

    func addHeader() { headers.append(HeaderRow()) }
    func removeHeader(_ id: UUID) { headers.removeAll { $0.id == id } }

    func backToForm() {
        stage = .form
        error = nil
    }

    /// The address, checked: the web's own sentences where it has them.
    private func checkedAddress(forAdding: Bool) -> String? {
        guard let parsed = McpServerURL.parse(url) else {
            error = "Enter the server's address, like https://mcp.example.com/mcp."
            return nil
        }
        let address = parsed.absoluteString
        if forAdding {
            if model.isAlreadyAdded(url: address) {
                error = "That server is already added."
                return nil
            }
            if model.isFull {
                error = "Limit of \(model.maxServers) MCP servers reached."
                return nil
            }
        }
        return address
    }

    /// Reads the server's tools without saving anything.
    func peek() async {
        guard let address = checkedAddress(forAdding: false), !isWorking else { return }
        let before = stage
        error = nil
        stage = .working("Looking inside…")
        do {
            let preview = try await client.send(.previewMcpServer(url: address, name: cleanName, headers: typedHeaders))
            stage = .preview(preview)
        } catch {
            handle(error, address: address, returningTo: before)
        }
    }

    /// Connects the server. Returns it when that worked.
    func add() async -> McpServer? {
        guard let address = checkedAddress(forAdding: true), !isWorking else { return nil }
        let before: Stage
        if case .preview = stage { before = stage } else { before = .form }
        error = nil
        stage = .working("Connecting… this can take up to a minute while the server is read.")
        let request = McpAddRequest(
            url: address, name: cleanName, headers: typedHeaders,
            registryId: registryId, saveToVault: saveToVault && hasHeaders
        )
        do {
            let answer = try await client.send(.addMcpServer(request))
            headers = []
            model.didAdd(answer.server, message: answer.message)
            Haptics.success()
            return answer.server
        } catch {
            handle(error, address: address, returningTo: before)
            return nil
        }
    }

    private func handle(_ failure: Error, address: String, returningTo previous: Stage) {
        if let hv = failure as? HVError {
            if case .cancelled = hv {
                stage = previous
                return
            }
            if hv.isMcpAuthRequired {
                let target = ToolsAuthTarget(url: address, name: cleanName, registryId: registryId)
                authFlow = ToolsAuthFlow(target: target, client: client, model: model)
                stage = .needsSignIn
                return
            }
            error = hv.userMessage
        } else {
            error = failure.localizedDescription
        }
        stage = previous
        Haptics.failure()
    }

}

#if DEBUG
extension ToolsAddFlow {
    /// A flow that is asking for a login, for previews and snapshots.
    func previewNeedsSignIn(client: HVClient, model: ToolsModel) {
        authFlow = ToolsAuthFlow(target: ToolsAuthTarget(url: url, name: name), client: client, model: model)
        stage = .needsSignIn
    }
}
#endif

struct ToolsAddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var flow: ToolsAddFlow
    @State private var showHeaders = false
    @State private var running: Task<Void, Never>?
    @State private var started = false
    @FocusState private var focus: Field?
    let model: ToolsModel

    private enum Field { case url, name }

    init(candidate: ToolsCandidate?, client: HVClient, model: ToolsModel) {
        self.model = model
        _flow = State(initialValue: ToolsAddFlow(candidate: candidate, client: client, model: model))
    }

    /// For previews, which need a flow already part way.
    init(flow: ToolsAddFlow, model: ToolsModel) {
        self.model = model
        _flow = State(initialValue: flow)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    stageContent
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(flow.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(flow.isWorking)
        .onAppear {
            // A server picked from the catalog is looked at straight away.
            guard flow.startsWithPreview, !started, case .form = flow.stage else { return }
            started = true
            running = Task { await flow.peek() }
        }
    }

    private var title: String {
        switch flow.stage {
        case .preview: return "What it offers"
        case .needsSignIn: return "Sign in"
        default: return "Add a server"
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch flow.stage {
        case .form: form
        case .working(let message): working(message)
        case .preview(let preview): previewContent(preview)
        case .needsSignIn:
            if let auth = flow.authFlow {
                ToolsAuthChallengeView(flow: auth, onConnected: { _ in dismiss() }, onCancel: { flow.backToForm() })
            }
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            Text("A server is a service your chats can use, like a calendar, a notes app or GitHub. Paste its address (usually ending in /mcp).")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: HV.Space.m) {
                HVLabeledField(title: "Server address") {
                    // The example is a verbatim prompt: as a plain string key SwiftUI links the URL, and the
                    // empty field then looks filled in, in link blue.
                    TextField("Server address", text: $flow.url, prompt: Text.hvPrompt("https://mcp.example.com/mcp"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focus = .name }
                }
                HVLabeledField(title: "Name (optional)") {
                    TextField("Name", text: $flow.name, prompt: Text.hvPrompt("Team notes"))
                        .focused($focus, equals: .name)
                        .submitLabel(.done)
                }
            }

            headersSection

            if let error = flow.error { errorText(error) }

            VStack(spacing: HV.Space.xs) {
                Button {
                    connect()
                } label: {
                    Text("Connect")
                }
                .buttonStyle(.hvPrimary)
                .disabled(flow.url.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("See its tools first") {
                    focus = nil
                    running = Task { await flow.peek() }
                }
                .buttonStyle(.hvSecondary)
                .disabled(flow.url.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("\(model.servers.count) of \(model.maxServers) servers connected.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            DisclosureGroup(isExpanded: $showHeaders) {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text("Some servers want a key in a header. It is encrypted on the server and never shown again.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach($flow.headers) { $row in
                        VStack(alignment: .leading, spacing: HV.Space.s) {
                            HVLabeledField(title: "Header name") {
                                TextField("Header name", text: $row.name, prompt: Text.hvPrompt("X-Api-Key"))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            HVLabeledField(title: "Value") {
                                SecureField("Value", text: $row.value, prompt: Text.hvPrompt("The key or token"))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button("Remove this header", role: .destructive) { flow.removeHeader(row.id) }
                                .buttonStyle(.hvGhost)
                                .padding(.leading, -HV.Space.s)
                        }
                    }
                    Button {
                        flow.addHeader()
                    } label: {
                        Label("Add a header", systemImage: "plus.circle")
                    }
                    .buttonStyle(.hvGhost)
                    if flow.hasHeaders {
                        Toggle(isOn: $flow.saveToVault) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save to the saved-secrets vault").font(.hvCallout)
                                Text("Keeps the key as a named secret you manage under Vault.")
                                    .font(.hvCaption)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
                .padding(.top, HV.Space.xs)
            } label: {
                Text("Needs an API key?").font(.hvCallout)
            }
            .onChange(of: showHeaders) { _, isOpen in
                if isOpen, flow.headers.isEmpty { flow.addHeader() }
            }
        }
        .hvCard()
    }

    private func connect() {
        focus = nil
        running = Task {
            if await flow.add() != nil { dismiss() }
        }
    }

    // MARK: Working

    private func working(_ message: String) -> some View {
        VStack(spacing: HV.Space.m) {
            ProgressView().controlSize(.large)
            Text(message)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { running?.cancel() }.buttonStyle(.hvGhost)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HV.Space.xxl)
        .accessibilityElement(children: .contain)
    }

    // MARK: Preview

    private func previewContent(_ preview: McpPreview) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            HStack(spacing: HV.Space.s) {
                HVIconBadge(symbol: "server.rack", tint: Palette.blue, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.name).font(.hvTitle3)
                    HVAddressText(URL(string: preview.url)?.host ?? preview.url)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if let transport = flow.transport { HVTag(text: McpRegistryEntry.transportLabel(for: transport)) }
            }

            Label(
                preview.tools.isEmpty
                    ? "This server did not list any tools."
                    : "\(preview.tools.count) tool\(preview.tools.count == 1 ? "" : "s"). Look them over before you add it.",
                systemImage: "checkmark.shield"
            )
            .hvRowLabel()
            .font(.hvCallout)
            .foregroundStyle(Palette.textSecondary)

            VStack(spacing: HV.Space.xs) {
                ForEach(preview.tools) { tool in
                    ToolsToolInspectorRow(tool: tool)
                }
            }

            if let error = flow.error { errorText(error) }

            VStack(spacing: HV.Space.xs) {
                Button {
                    connect()
                } label: {
                    Text("Add to my tools")
                }
                .buttonStyle(.hvPrimary)
                Button("Back") { flow.backToForm() }.buttonStyle(.hvGhost)
            }
        }
    }

    private func errorText(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").hvRowLabel()
            .font(.hvFootnote)
            .foregroundStyle(Palette.danger)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One tool in the preview: its name, what it says it does, and its parameters.
/// Everything here comes from the server being inspected, so it is plain text only.
struct ToolsToolInspectorRow: View {
    let tool: McpToolInfo
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                if !tool.description.isEmpty {
                    Text(tool.description).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
                let parameters = tool.parameters
                if parameters.isEmpty {
                    Text("No parameters.").font(.hvCaption).foregroundStyle(Palette.textTertiary)
                } else {
                    ForEach(parameters) { parameter in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(parameter.name).font(.hvMono)
                                if let type = parameter.type { Text(type).font(.hvCaption).foregroundStyle(Palette.textTertiary) }
                                if parameter.isRequired { Text("required").font(.hvCaption).foregroundStyle(Palette.blue) }
                            }
                            if let summary = parameter.summary {
                                Text(summary).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, HV.Space.xs)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.hvMono).foregroundStyle(Palette.textPrimary)
                if !expanded, !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .hvCard(padding: HV.Space.s, radius: HV.Radius.m)
    }
}
