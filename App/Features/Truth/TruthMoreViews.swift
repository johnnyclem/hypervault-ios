import HyperVaultKit
import SwiftUI

// The quieter screens behind the ledger page's menu: what changed, what is out
// of date, who signs, and the sidecar's inbox.

// MARK: Notices

/// What changed in the ledger: your entries that were challenged, overturned,
/// upheld, verified, undermined or mended, newest first.
struct TruthNoticesScreen: View {
    @State private var phase: TruthLoad<[TruthEvent]> = .loading
    private let client: HVClient

    init(client: HVClient) {
        self.client = client
    }

    var body: some View {
        List {
            switch phase {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                HVErrorState(message: message) { Task { await load() } }.listRowBackground(Color.clear)
            case .loaded(let events):
                if events.isEmpty {
                    HVEmptyState(symbol: "bell", title: "Nothing has changed.", message: "When one of your entries is challenged, overturned, verified or undermined, it shows up here.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: HV.Space.xxs) {
                            HStack(spacing: HV.Space.xs) {
                                TruthTypeTag(type: event.entryType)
                                HVTag(text: event.kind.title, tint: event.kind.isSetback ? Palette.amber : Palette.mint)
                                Spacer(minLength: 0)
                                if let when = event.createdAt {
                                    Text(when.formatted(date: .abbreviated, time: .shortened)).font(.hvCaption).foregroundStyle(Palette.textTertiary)
                                }
                            }
                            Text(verbatim: event.summary).font(.hvCallout)
                            if let by = event.byAuthor {
                                Text("By \(by)").font(.hvCaption).foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .padding(.vertical, HV.Space.xxs)
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Palette.surface)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Notices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            phase = .loaded(try await client.send(.truthEvents()).events)
        } catch {
            phase = .failed(TruthModel.sentence(error))
        }
    }
}

// MARK: Out of date

/// The worklist: memories and pages whose facts moved since they last saw them.
@MainActor
@Observable
final class TruthStaleModel {
    private(set) var phase: TruthLoad<TruthStaleWorklist> = .loading
    private(set) var busy: Set<String> = []
    @ObservationIgnored private let client: HVClient

    init(client: HVClient) {
        self.client = client
    }

    func load() async {
        do {
            phase = .loaded(try await client.send(.truthStale()))
        } catch {
            phase = .failed(TruthModel.sentence(error))
        }
    }

    func resolve(_ resolution: TruthStaleResolution, item: TruthStaleItem, edge: TruthStaleEdge? = nil) async throws {
        guard let context = item.item else { return }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        let entries = edge.map { [$0.entryId] } ?? item.edges.map(\.entryId)
        let successors = edge?.successor.map { [$0.id] } ?? []
        _ = try await client.send(.resolveTruthStale(resolution, item: context, entries: entries, to: successors, ledger: item.ledger?.slug))
        await load()
    }
}

struct TruthStaleScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: TruthStaleModel
    @State private var confirmStop: TruthStaleItem?

    init(client: HVClient) {
        _model = State(initialValue: TruthStaleModel(client: client))
    }

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }.listRowBackground(Color.clear)
            case .loaded(let worklist):
                if worklist.items.isEmpty {
                    HVEmptyState(symbol: "checkmark.seal", title: "Nothing is out of date.", message: "Every memory and page still rests on facts as it last saw them.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(worklist.items) { item in
                        itemSection(item)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Out of date")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog(
            "Stop tracking this?",
            isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }),
            titleVisibility: .visible,
            presenting: confirmStop
        ) { item in
            Button("Stop tracking", role: .destructive) { resolve(.unlink, item: item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.item?.title ?? "This item") will no longer be marked when these facts change.")
        }
    }

    private func itemSection(_ item: TruthStaleItem) -> some View {
        Section {
            ForEach(item.edges) { edge in
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text(edge.whatMoved).font(.hvCallout)
                    if let entry = edge.entry { TruthBriefRow(entry: entry) }
                    if let successor = edge.successor {
                        Text("Replaced by").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                        TruthBriefRow(entry: successor)
                        Button("Move to the new one") { resolve(.relink, item: item, edge: edge) }
                            .buttonStyle(.hvGhost)
                            .frame(minHeight: 44)
                    }
                }
                .padding(.vertical, HV.Space.xxs)
            }
            HStack {
                Button("Still fine") { resolve(.reaffirm, item: item) }
                Spacer()
                Button("Stop tracking", role: .destructive) { confirmStop = item }
            }
            .buttonStyle(.hvGhost)
            .frame(minHeight: 44)
            .disabled(model.busy.contains(item.id))
        } header: {
            Button {
                open(item)
            } label: {
                HStack(spacing: HV.Space.xs) {
                    Image(systemName: item.item?.isMemory == true ? "brain.head.profile" : "doc.text")
                    Text(verbatim: item.item?.title ?? "Untitled").font(.hvHeadline).lineLimit(2)
                    Spacer(minLength: 0)
                    if canOpen(item) { Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)) }
                }
                .foregroundStyle(Palette.textPrimary)
                .frame(minHeight: 44)
                .textCase(nil)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen(item))
        }
        .listRowBackground(Palette.surface)
    }

    private func canOpen(_ item: TruthStaleItem) -> Bool {
        guard let context = item.item else { return false }
        return context.isMemory || context.slug != nil
    }

    private func open(_ item: TruthStaleItem) {
        guard let context = item.item else { return }
        if context.isMemory {
            app.router.open(.route(.memory(id: context.id)))
        } else if let slug = context.slug {
            app.router.open(.route(.artifact(slug: slug)))
        }
    }

    private func resolve(_ resolution: TruthStaleResolution, item: TruthStaleItem, edge: TruthStaleEdge? = nil) {
        Task {
            do {
                try await model.resolve(resolution, item: item, edge: edge)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

// MARK: Signers

/// Who signs: the name you chose, and the agents on your account.
struct TruthSignersScreen: View {
    @Environment(AppModel.self) private var app
    @State private var phase: TruthLoad<TruthSigners> = .loading
    private let client: HVClient

    init(client: HVClient) {
        self.client = client
    }

    var body: some View {
        List {
            switch phase {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                HVErrorState(message: message) { Task { await load() } }.listRowBackground(Color.clear)
            case .loaded(let signers):
                Section {
                    if let handle = signers.handle {
                        Label(handle, systemImage: "person.fill").font(.hvBody)
                    } else {
                        TruthHandleForm { try await save($0) }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("You")
                } footer: {
                    Text(signers.handle == nil
                        ? "You have not chosen a name yet."
                        : "The name on every TB you assert and every decision you make. It is set once.")
                }
                Section {
                    if signers.agents.isEmpty {
                        Text("No agent keys yet.").foregroundStyle(Palette.textSecondary)
                    }
                    ForEach(signers.agents) { signer in
                        Label(signer.id, systemImage: "sparkle")
                    }
                } header: {
                    Text("Your agents")
                } footer: {
                    Text("An agent signs its UVs as agent:<its key name>. Nothing an agent writes is a TB: a person promotes it.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Signers")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            phase = .loaded(try await client.send(.truthSigners))
        } catch {
            phase = .failed(TruthModel.sentence(error))
        }
    }

    private func save(_ handle: String) async throws {
        if let problem = TruthHandle.problem(handle) { throw HVError.invalidRequest(problem) }
        _ = try await client.send(.setTruthHandle(handle))
        await load()
    }
}

// MARK: The sidecar's inbox

@MainActor
@Observable
final class TruthSidecarModel {
    private(set) var phase: TruthLoad<TruthInbox> = .loading
    private(set) var busy: Set<String> = []
    private(set) var needsHandle = false
    @ObservationIgnored private let client: HVClient

    init(client: HVClient) {
        self.client = client
    }

    func load() async {
        do {
            phase = .loaded(try await client.send(.truthInbox))
        } catch {
            phase = .failed(TruthModel.sentence(error))
        }
    }

    func saveHandle(_ text: String) async throws {
        if let problem = TruthHandle.problem(text) { throw HVError.invalidRequest(problem) }
        _ = try await client.send(.setTruthHandle(text))
        needsHandle = false
    }

    func notarize(_ proposal: SidecarProposal) async throws {
        busy.insert(proposal.id)
        defer { busy.remove(proposal.id) }
        do {
            _ = try await client.send(.notarizeTruth(id: proposal.id))
            await load()
        } catch {
            if (error as? HVError)?.isTruthHandleRequired == true { needsHandle = true }
            throw error
        }
    }

    func dismiss(_ proposal: SidecarProposal, reason: String) async throws {
        busy.insert(proposal.id)
        defer { busy.remove(proposal.id) }
        do {
            _ = try await client.send(.dismissSidecarProposal(id: proposal.id, reason: reason))
            await load()
        } catch {
            if (error as? HVError)?.isTruthHandleRequired == true { needsHandle = true }
            throw error
        }
    }
}

/// The stenographer sidecar's own queue: proposals waiting for a notary, and
/// objections it raised against replies that contradict a TB.
struct TruthSidecarScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: TruthSidecarModel
    @State private var dismissing: SidecarProposal?
    @State private var reason = ""

    init(client: HVClient) {
        _model = State(initialValue: TruthSidecarModel(client: client))
    }

    var body: some View {
        List {
            if model.needsHandle {
                TruthHandleForm { try await model.saveHandle($0) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            switch model.phase {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }.listRowBackground(Color.clear)
            case .loaded(let inbox):
                if !inbox.notary {
                    Text("Notarizing and dismissing are off on this server, so this inbox is read-only here.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .listRowBackground(Color.clear)
                }
                proposals(inbox)
                objections(inbox)
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Sidecar inbox")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert(
            "Why dismiss this?",
            isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }),
            presenting: dismissing
        ) { proposal in
            TextField("Reason", text: $reason)
            Button("Dismiss") { finishDismiss(proposal) }
            Button("Cancel", role: .cancel) { reason = "" }
        } message: { _ in
            Text("The sidecar keeps your reason with the proposal.")
        }
    }

    @ViewBuilder
    private func proposals(_ inbox: TruthInbox) -> some View {
        Section {
            if let list = inbox.proposals {
                if list.isEmpty { Text("Nothing waiting.").foregroundStyle(Palette.textSecondary) }
                ForEach(list) { proposal in
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        HStack(spacing: HV.Space.xs) {
                            TruthTypeTag(type: proposal.isTombstone ? .tb : .uv)
                            if proposal.requiresNotary { HVTag(text: "Needs a notary", tint: Palette.blue) }
                        }
                        TruthClaimText(text: proposal.headline, lines: 4)
                        if let basis = proposal.basis { Text("Basis: \(basis)").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
                        if let signal = proposal.signalDetail { Text("Signal: \(signal)").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
                        Text([proposal.author.map { "drafted by \($0)" }, proposal.createdAt?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textTertiary)
                        HStack {
                            Button("Notarize") { notarize(proposal) }
                                .buttonStyle(.hvGhost)
                                .disabled(!inbox.notary || model.busy.contains(proposal.id))
                            Spacer()
                            Button("Dismiss") { dismissing = proposal }
                                .buttonStyle(.hvGhost)
                                .disabled(!inbox.notary || model.busy.contains(proposal.id))
                        }
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, HV.Space.xxs)
                }
            } else {
                Text("The sidecar did not answer its proposals route. It may be down.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Awaiting a notary")
        } footer: {
            Text("Notarizing signs the proposal under your truth handle.")
        }
    }

    @ViewBuilder
    private func objections(_ inbox: TruthInbox) -> some View {
        Section {
            if let list = inbox.objections {
                if list.isEmpty { Text("No objections pending.").foregroundStyle(Palette.textSecondary) }
                ForEach(list) { objection in
                    VStack(alignment: .leading, spacing: 3) {
                        if let literal = objection.literal { Text("“\(literal)”").font(.system(.callout, design: .serif)).italic() }
                        if let text = objection.objection { Text(verbatim: text).font(.hvCallout) }
                        if let tb = objection.tbId { Text("Contradicts TB \(TruthID.short(tb))").font(.hvCaption).foregroundStyle(Palette.textTertiary) }
                    }
                    .padding(.vertical, HV.Space.xxs)
                }
            } else {
                Text("The sidecar did not answer its flags route. Objections are only served when it is set to deliver them.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("Pending objections")
        }
    }

    private func notarize(_ proposal: SidecarProposal) {
        Task {
            do {
                try await model.notarize(proposal)
                Haptics.success()
                app.toasts.success("Notarized: the sidecar minted the entry.")
            } catch {
                if (error as? HVError)?.isTruthHandleRequired != true { app.toasts.show(error: error) }
            }
        }
    }

    private func finishDismiss(_ proposal: SidecarProposal) {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        reason = ""
        guard !text.isEmpty else {
            app.toasts.show("A reason is needed to dismiss.", style: .error)
            return
        }
        Task {
            do {
                try await model.dismiss(proposal, reason: text)
                app.toasts.success("Dismissed.")
            } catch {
                if (error as? HVError)?.isTruthHandleRequired != true { app.toasts.show(error: error) }
            }
        }
    }
}
