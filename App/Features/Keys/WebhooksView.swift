import HyperVaultKit
import SwiftUI

// Signed outbound webhooks: where HyperVault tells an agent that a truth it cares about was challenged,
// overturned or undermined (docs/truth-events.md). A power-user corner, tucked under Advanced.

@MainActor
@Observable
final class WebhooksModel {
    enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var hooks: [OutboundWebhook] = []
    private(set) var events: [String] = WebhookRules.knownEvents
    private(set) var signing: WebhookSigning?
    private(set) var changing: Set<String> = []

    private let client: HVClient

    init(client: HVClient) {
        self.client = client
    }

    func load() async {
        do {
            let list = try await client.send(.webhooks)
            hooks = list.webhooks
            events = list.events.isEmpty ? WebhookRules.knownEvents : list.events
            signing = list.signing
            phase = .loaded
        } catch {
            if case .loaded = phase {} else { phase = .failed(keysMessage(for: error)) }
        }
    }

    /// Registers a hook. The answer holds the signing secret, once; the caller shows it and lets it go.
    func create(url: String, name: String, events: [String]?, authors: [String]) async throws -> CreatedWebhook {
        let created = try await client.send(.createWebhook(url: url, name: name, events: events, authors: authors))
        hooks.insert(created.webhook, at: 0)
        return created
    }

    func delete(_ hook: OutboundWebhook) async throws {
        changing.insert(hook.id)
        defer { changing.remove(hook.id) }
        _ = try await client.send(.deleteWebhook(id: hook.id))
        hooks.removeAll { $0.id == hook.id }
    }

    func setEnabled(_ hook: OutboundWebhook, _ enabled: Bool) async throws {
        changing.insert(hook.id)
        defer { changing.remove(hook.id) }
        let answer = try await client.send(.setWebhookEnabled(id: hook.id, enabled: enabled))
        if let index = hooks.firstIndex(where: { $0.id == hook.id }) { hooks[index] = answer.webhook }
    }

    func test(_ hook: OutboundWebhook) async throws -> WebhookTestResult {
        changing.insert(hook.id)
        defer { changing.remove(hook.id) }
        return try await client.send(.testWebhook(id: hook.id))
    }

    func deliveries(of hook: OutboundWebhook) async -> [WebhookDelivery] {
        (try? await client.send(.webhookDetail(id: hook.id)))?.deliveries ?? []
    }
}

private enum WebhookDestination: Hashable {
    case hook(String)
}

struct WebhooksView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app

    @State private var model: WebhooksModel?
    @State private var adding = false

    var body: some View {
        Group {
            if let model { content(model) } else { HVLoadingState().frame(maxHeight: .infinity) }
        }
        .hvScreenBackground()
        .navigationTitle("Webhooks")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: WebhookDestination.self) { destination in
            switch destination {
            case .hook(let id):
                if let model { WebhookDetailView(hookID: id, model: model) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a webhook")
            }
        }
        .task {
            if model == nil { model = WebhooksModel(client: env.client) }
            await model?.load()
        }
        .sheet(isPresented: $adding) {
            if let model { AddWebhookSheet(model: model) }
        }
    }

    @ViewBuilder
    private func content(_ model: WebhooksModel) -> some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 3).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded:
            if model.hooks.isEmpty {
                VStack(spacing: HV.Space.m) {
                    HVEmptyState(
                        symbol: "dot.radiowaves.left.and.right", title: "No webhooks",
                        message: "A webhook is an address HyperVault posts to when one of your truths is challenged, overturned or undermined. Each post is signed, so the receiver can check it came from here."
                    )
                    Button("Add a webhook") { adding = true }.buttonStyle(.hvSecondary).frame(maxWidth: 280)
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section(footer: Text("Each post carries a signature header the receiver checks with the secret shown when you add the webhook.").font(.hvCaption)) {
                        ForEach(model.hooks) { hook in
                            NavigationLink(value: WebhookDestination.hook(hook.id)) { WebhookRow(hook: hook) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await model.load() }
            }
        }
    }
}

private struct WebhookRow: View {
    let hook: OutboundWebhook

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: "dot.radiowaves.left.and.right", tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(hook.title).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(summary).font(.hvFootnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: HV.Space.xs)
            if !hook.enabled { HVTag(text: "Off", tint: Palette.textSecondary) } else if hook.isFailing { HVTag(text: "Failing", tint: Palette.warning) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var tint: Color { !hook.enabled ? Palette.textSecondary : (hook.isFailing ? Palette.warning : Palette.coral) }

    private var summary: String {
        let events = hook.events.contains("truth.*") ? "Everything" : hook.events.map(WebhookRules.eventTitle).joined(separator: ", ")
        return events
    }
}

// MARK: Detail

private struct WebhookDetailView: View {
    let hookID: String
    let model: WebhooksModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: WebhookTestResult?
    @State private var confirmDelete = false
    @State private var deliveries: [WebhookDelivery] = []

    var body: some View {
        Group {
            if let hook = model.hooks.first(where: { $0.id == hookID }) {
                details(hook)
            } else {
                HVEmptyState(symbol: "dot.radiowaves.left.and.right", title: "This webhook is gone", actionTitle: "Back") { dismiss() }
                    .frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Webhook")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func details(_ hook: OutboundWebhook) -> some View {
        List {
            Section {
                LabeledContent("Name", value: hook.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Posts to").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    Text(hook.url).font(.hvMono).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Events", value: hook.events.contains("truth.*") ? "Everything" : hook.events.map(WebhookRules.eventTitle).joined(separator: ", "))
                if !hook.authors.isEmpty { LabeledContent("Only for", value: hook.authors.joined(separator: ", ")) }
                if let last = hook.lastDeliveredAt { LabeledContent("Last delivered", value: AccountWords.agoLine(seconds: Date().timeIntervalSince(last))) }
                if hook.isFailing {
                    Text("\(hook.consecutiveFailures) failed in a row. After \(WebhookRules.disableAfterFailures) in a row it is switched off.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.warning)
                }
            }

            Section {
                Toggle("Send events", isOn: Binding(get: { hook.enabled }, set: { setEnabled(hook, $0) }))
                    .disabled(model.changing.contains(hook.id))
                Button {
                    Task { await test(hook) }
                } label: {
                    HStack {
                        Label("Send a test", systemImage: "paperplane")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing)
                if let testResult {
                    Text(testResult.summary)
                        .font(.hvFootnote)
                        .foregroundStyle(testResult.ok ? Palette.success : Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("A test is a signed truth.test ping, sent now.")
            }

            if !deliveries.isEmpty {
                Section(header: HVSectionHeader(title: "Recent deliveries")) {
                    ForEach(deliveries) { delivery in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(delivery.status?.capitalized ?? "Sent").font(.hvBody)
                                if let created = delivery.createdAt {
                                    Text(AccountWords.agoLine(seconds: Date().timeIntervalSince(created))).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                                }
                            }
                            Spacer()
                            if let status = delivery.lastStatus { Text("\(status)").font(.hvMono).foregroundStyle(Palette.textSecondary) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete webhook", systemImage: "trash").foregroundStyle(Palette.danger) }
                    .disabled(model.changing.contains(hook.id))
            } footer: {
                Text("It stops at once, and its delivery history goes with it.")
            }
        }
        .scrollContentBackground(.hidden)
        .task { deliveries = await model.deliveries(of: hook) }
        .confirmationDialog("Delete \(hook.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete webhook", role: .destructive) { delete(hook) }
            Button("Keep it", role: .cancel) {}
        }
    }

    private func test(_ hook: OutboundWebhook) async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            testResult = try await model.test(hook)
            if testResult?.ok == true { Haptics.success() } else { Haptics.warning() }
        } catch {
            app.toasts.show(error: error)
        }
    }

    private func setEnabled(_ hook: OutboundWebhook, _ enabled: Bool) {
        Task {
            do { try await model.setEnabled(hook, enabled) } catch { app.toasts.show(error: error) }
        }
    }

    private func delete(_ hook: OutboundWebhook) {
        Task {
            do {
                try await model.delete(hook)
                Haptics.success()
                app.toasts.success("Webhook deleted.")
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

// MARK: Add

private struct AddWebhookSheet: View {
    let model: WebhooksModel

    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var name = ""
    @State private var everything = true
    @State private var chosen: Set<String> = []
    @State private var authors = ""
    @State private var saving = false
    @State private var error: String?
    /// Held only while this sheet is open; shown once.
    @State private var secret: String?
    @State private var copiedSecret = false

    var body: some View {
        NavigationStack {
            Group {
                if let secret { secretView(secret) } else { form }
            }
            .hvScreenBackground()
            .navigationTitle(secret == nil ? "Add a webhook" : "Signing secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(secret == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(secret != nil && !copiedSecret)
        .onDisappear { secret = nil }
    }

    private var form: some View {
        Form {
            Section(footer: Text("Where HyperVault posts. Private and local addresses are refused.")) {
                TextField("https://example.com/hooks/hypervault", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Name (optional)", text: $name)
            }

            Section(header: Text("Events")) {
                Toggle("Everything", isOn: $everything)
                if !everything {
                    ForEach(model.events.filter { $0 != "truth.*" }, id: \.self) { event in
                        Toggle(WebhookRules.eventTitle(event), isOn: Binding(
                            get: { chosen.contains(event) },
                            set: { if $0 { chosen.insert(event) } else { chosen.remove(event) } }
                        ))
                    }
                }
            }

            Section(footer: Text("Only entries whose author or signer is named are delivered. Leave empty for all. Separate names with commas.")) {
                TextField("Only for (optional)", text: $authors)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                if let error { KeysInlineMessage(text: error) }
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().tint(.white) } else { Text("Add webhook") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(!canSave || saving)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var canSave: Bool {
        WebhookRules.validate(url: url) == nil && (everything || !chosen.isEmpty)
    }

    private func save() async {
        if let problem = WebhookRules.validate(url: url) {
            error = problem
            return
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let created = try await model.create(
                url: url.trimmingCharacters(in: .whitespacesAndNewlines), name: name,
                events: everything ? nil : model.events.filter { chosen.contains($0) },
                authors: WebhookRules.authors(from: authors)
            )
            secret = created.secret
            Haptics.success()
        } catch {
            self.error = keysMessage(for: error)
            Haptics.failure()
        }
    }

    private func secretView(_ secret: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Label("Webhook added", systemImage: "checkmark.circle.fill")
                    .font(.hvTitle3)
                    .foregroundStyle(Palette.success)
                Text("Store this secret now. It is shown once, and your receiver needs it to check each post's signature.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                Text(secret)
                    .font(.system(.footnote, design: .monospaced, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HV.Space.s + 2)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                    .accessibilityLabel("Signing secret, shown once. Use the copy button.")
                    .keysHidesWhenInactive()
                KeysCopyButton(title: "Copy secret", text: secret, isSecret: true, style: .primary) { copiedSecret = true }
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text("How to check a post").font(.hvHeadline)
                    Text("Each post has X-HyperVault-Signature: t=<unix seconds>,v1=<hex>. The hex is the HMAC-SHA256 of \"<t>.<raw body>\" with this secret. Reject a post when the time is more than 300 seconds off.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    Text("A 2xx within 10 seconds counts as delivered. A failed post is tried again five times; after 25 failures in a row the webhook is switched off.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
    }
}

#if DEBUG
private let webhooksPreviewJSON = #"""
{"webhooks":[{"id":"w1","name":"grok","url":"https://agent.example/hooks/hv","events":["truth.challenged","truth.overturned"],"authors":["grok"],"enabled":true,"consecutive_failures":0,"last_delivered_at":"2026-10-25T10:00:00Z","last_status":200,"created_at":"2026-10-20T10:00:00Z"},
 {"id":"w2","name":"","url":"https://hooks.example.org/in","events":["truth.*"],"authors":[],"enabled":true,"consecutive_failures":3,"last_delivered_at":null,"last_status":502,"created_at":"2026-10-21T10:00:00Z"}],
 "events":["truth.*","truth.challenged","truth.overturned","truth.upheld","truth.verified","truth.undermined","truth.restored"]}
"""#

#Preview("Webhooks") {
    KeysPreviewHost(routes: [.json(.get, "/api/webhooks", webhooksPreviewJSON)]) { WebhooksView() }
}

#Preview("Webhooks, none") {
    KeysPreviewHost(routes: [.json(.get, "/api/webhooks", #"{"webhooks":[],"events":["truth.*"]}"#)]) { WebhooksView() }
}
#endif
