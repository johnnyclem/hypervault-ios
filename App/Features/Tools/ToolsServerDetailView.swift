import HyperVaultKit
import SwiftUI

/// One connected server: switch it on or off, choose its tools, read its tool
/// list again, sign in again, or remove it.
struct ToolsServerDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: ToolsModel
    let serverID: String
    let client: HVClient

    @State private var query = ""
    @State private var confirmRemove = false
    @State private var signIn: ToolsAuthFlow?

    var body: some View {
        Group {
            if let server = model.server(id: serverID) {
                detail(server)
            } else {
                HVEmptyState(symbol: "checkmark.circle", title: "Removed", message: "This server is no longer connected.")
            }
        }
        .hvScreenBackground()
        .navigationTitle(model.server(id: serverID)?.name ?? "Server")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $signIn) { flow in
            ToolsReauthSheet(flow: flow) { _ in
                signIn = nil
                app.toasts.success("Signed in again.")
            }
        }
    }

    private func detail(_ server: McpServer) -> some View {
        List {
            Section { header(server) }
                .hvListRow()

            Section(footer: Text("Takes effect for new chats after you compile.").hvSectionNote()) {
                Toggle("Use in chats", isOn: Binding(
                    get: { server.enabled },
                    set: { value in Task { await model.setEnabled(value, serverID: server.id) } }
                ))
                .tint(Palette.mint)
            }
            .hvListRow()

            toolsSection(server)

            Section(header: HVSectionHeader(title: "Manage")) {
                refreshRow(server)
                signInRows(server)
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Remove this server", systemImage: HVSymbol.delete).hvRowLabel(role: .destructive)
                }
                .confirmationDialog("Remove \(server.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) {
                        Task { if await model.remove(serverID: server.id) { dismiss() } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Your chats keep using what is already compiled until you compile again. You can add the server back later.")
                }
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .modifier(ToolsOptionalSearch(isOn: server.tools.count > 10, text: $query, prompt: "Find a tool"))
        .refreshable { await model.refresh(serverID: server.id) }
    }

    // MARK: Header

    private func header(_ server: McpServer) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text(server.url)
                .font(.hvMono)
                .foregroundStyle(Palette.textSecondary)
                // An address is read as one thing: kept to a line or two, shrunk a little, with its middle left out rather
                // than broken at a hyphen ("mcp.lin-/ear.app").
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: HV.Space.xs) {
                switch server.authType {
                case .oauth: HVTag(text: "Signed in with a login", tint: Palette.mint)
                case .headers: HVTag(text: "Uses a key or token", tint: Palette.blue)
                case .none: HVTag(text: "No sign-in needed")
                }
                if model.needsSignIn.contains(server.id) { HVTag(text: "Sign in again", tint: Palette.amber) }
            }
            if server.secretBacked {
                Label("The sign-in is kept in your saved-secrets vault.", systemImage: "lock.shield.fill").hvRowLabel()
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            if let read = server.introspectedAt {
                Text("Tools read \(read.formatted(.relative(presentation: .named))).")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, HV.Space.xxs)
    }

    // MARK: Tools

    private func visibleTools(_ server: McpServer) -> [McpToolInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return server.tools }
        return server.tools.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.description.localizedCaseInsensitiveContains(needle)
        }
    }

    @ViewBuilder
    private func toolsSection(_ server: McpServer) -> some View {
        Section(header: HVSectionHeader(title: "Tools", detail: server.tools.isEmpty ? nil : "\(server.enabledToolCount) of \(server.tools.count) on")) {
            if server.tools.isEmpty {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text("No tools listed").font(.hvHeadline)
                    Text("Read the tool list again. If the server still lists nothing, it may need you to sign in.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            } else {
                Menu {
                    Button { model.setAllTools(on: true, serverID: server.id) } label: { Label("Turn all on", systemImage: "checkmark.circle") }
                    Button { model.setAllTools(on: false, serverID: server.id) } label: { Label("Turn all off", systemImage: "circle") }
                } label: {
                    Label("Turn all on or off", systemImage: "switch.2")
                }
                .disabled(!server.enabled)

                let tools = visibleTools(server)
                if tools.isEmpty {
                    Text("No tool matches “\(query)”.").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
                ForEach(tools) { tool in
                    Toggle(isOn: Binding(
                        get: { server.isToolEnabled(tool.name) },
                        set: { model.setTool(tool.name, on: $0, serverID: server.id) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.hvMono).foregroundStyle(Palette.textPrimary)
                            if !tool.description.isEmpty {
                                Text(tool.description)
                                    .font(.hvFootnote)
                                    .foregroundStyle(Palette.textSecondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                    .tint(Palette.mint)
                    .disabled(!server.enabled)
                    .frame(minHeight: 44)
                }
            }
        }
        .hvListRow()
    }

    // MARK: Manage

    private func refreshRow(_ server: McpServer) -> some View {
        Button {
            Task { await model.refresh(serverID: server.id) }
        } label: {
            HStack {
                Label("Read the tool list again", systemImage: "arrow.clockwise").hvRowLabel()
                if model.busy.contains(server.id) {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(model.busy.contains(server.id))
    }

    @ViewBuilder
    private func signInRows(_ server: McpServer) -> some View {
        if server.authType == .oauth || model.needsSignIn.contains(server.id) && server.authType != .headers {
            Button {
                signIn = ToolsAuthFlow(target: target(server), client: client, model: model)
            } label: {
                Label("Sign in again", systemImage: "person.badge.key").hvRowLabel()
            }
        }
        if server.authType == .headers {
            if server.secretBacked {
                Button {
                    app.router.open(.account(.vault))
                } label: {
                    Label("Change the key in Vault", systemImage: HVSymbol.vault).hvRowLabel()
                }
            } else {
                Button {
                    let flow = ToolsAuthFlow(target: target(server), client: client, model: model)
                    flow.useToken()
                    signIn = flow
                } label: {
                    Label("Replace the token", systemImage: HVSymbol.key).hvRowLabel()
                }
            }
        }
    }

    private func target(_ server: McpServer) -> ToolsAuthTarget {
        ToolsAuthTarget(url: server.url, name: server.name, registryId: server.registryId, existing: server)
    }
}

/// A search field, only when there are enough rows to need one.
struct ToolsOptionalSearch: ViewModifier {
    let isOn: Bool
    @Binding var text: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            content.searchable(text: $text, prompt: prompt)
        } else {
            content
        }
    }
}

extension ToolsAuthFlow: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Signing in again to a server that is already connected.
struct ToolsReauthSheet: View {
    @Environment(\.dismiss) private var dismiss
    let flow: ToolsAuthFlow
    var onConnected: (McpServer) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                ToolsAuthChallengeView(flow: flow, onConnected: onConnected, onCancel: { dismiss() })
                    .padding(HV.Space.m)
                    .hvReadableWidth()
            }
            .hvScreenBackground()
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(flow.isWorking) }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(flow.isWorking)
    }
}

#if DEBUG
#Preview("Server") {
    PreviewHost(routes: ToolsFixtures.routes) {
        ToolsModelHost { model, client in ToolsServerDetailView(model: model, serverID: "s1", client: client) }
    }
}
#endif
