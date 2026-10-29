import HyperVaultKit
import SwiftUI

/// "Fix it": hands a page that will not render to the person's connected
/// model, which tries to make it load again. The model's round trip can run for
/// a minute, so the server answers at once with a job and this polls it; the
/// job keeps going if the sheet is closed.
@MainActor
@Observable
final class ArtifactRepairModel {
    enum Phase: Equatable {
        case idle
        case running
        case done(changed: Bool, message: String)
        case failed(message: String, needsBackend: Bool)
    }

    private(set) var phase: Phase = .idle
    /// The models the person has connected, once they have been read. With more than one the repair asks which.
    private(set) var backends: [ChatBackend] = []
    /// The list was read, so an empty one means no model is connected, which is not the same as not knowing.
    private(set) var backendsKnown = false
    var selectedBackendID: String?
    private let client: HVClient
    private let slug: String
    private let pollInterval: UInt64
    /// How long to keep asking before saying it is still working: three minutes.
    private let maxPolls = 90
    /// The sheet has been closed, so no one is waiting for the answer any more.
    @ObservationIgnored private var closed = false

    init(client: HVClient, slug: String, pollInterval: UInt64 = 2_000_000_000) {
        self.client = client
        self.slug = slug
        self.pollInterval = pollInterval
    }

    /// No model is connected, as far as a list that was read says. The attempt would only be refused, so the sheet says so first.
    var needsModel: Bool { backendsKnown && backends.isEmpty }

    /// The models to choose among. A list that could not be read leaves the choice to the server.
    func loadBackends() async {
        guard !backendsKnown, let list = try? await client.send(.backends) else { return }
        backends = list
        backendsKnown = true
        if !list.contains(where: { $0.id == selectedBackendID }) { selectedBackendID = list.first?.id }
    }

    /// The sheet was closed. The job goes on, but the answer would reach no one here, so this stops asking and does not
    /// acknowledge it: the job notice (`JobNotices`) tells of it the next time Home or the Library is showing.
    func stopWaiting() {
        closed = true
    }

    func run(renderError: String?) async {
        phase = .running
        let start: ArtifactRepairStart
        do {
            // Only a person who had a choice is asked what it was; with one model the server's default is that model.
            let chosen = backends.count > 1 ? selectedBackendID : nil
            start = try await client.send(.repairArtifact(slug: slug, renderError: renderError, backendId: chosen))
        } catch let error as HVError {
            phase = .failed(message: error.userMessage, needsBackend: error.failure?.body?["needs_backend"]?.bool == true)
            return
        } catch {
            phase = .failed(message: ArtifactErrors.message(error), needsBackend: false)
            return
        }

        for _ in 0..<maxPolls {
            guard !Task.isCancelled, !closed else { return }
            if let job = try? await client.send(.artifactJob(id: start.jobId)), job.isFinished {
                guard !closed else { return }
                // Tell the server it has been seen, so it stops being announced.
                _ = try? await client.send(.acknowledgeArtifactJob(id: job.id))
                if job.status == .succeeded {
                    phase = .done(changed: job.result?.changed == true, message: job.result?.message ?? "Done.")
                } else {
                    phase = .failed(message: job.error ?? "The repair failed.", needsBackend: false)
                }
                return
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        phase = .failed(message: "It is still working. Close this and look again in a minute.", needsBackend: false)
    }
}

struct ArtifactRepairSheet: View {
    let detail: ArtifactDetailModel
    /// The error the page itself caught, when the "Fix it" link carried one.
    let renderError: String?
    var onRepaired: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model: ArtifactRepairModel

    init(detail: ArtifactDetailModel, renderError: String?, onRepaired: @escaping () -> Void = {}) {
        self.detail = detail
        self.renderError = renderError
        self.onRepaired = onRepaired
        _model = State(initialValue: ArtifactRepairModel(client: detail.env.client, slug: detail.slug))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    Text(explanation)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)

                    if let renderError, !renderError.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("What the page ran into").font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
                            Text(renderError)
                                .font(.hvMono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .hvCard()
                    }

                    modelChoice

                    result
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .hvScreenBackground()
            .navigationTitle("Fix it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await model.loadBackends() }
        .onDisappear { model.stopWaiting() }
    }

    /// Which model repairs the page, when there is more than one; and, before any attempt, that there is none.
    @ViewBuilder
    private var modelChoice: some View {
        if model.backends.count > 1 {
            LabeledContent("Repair with") {
                Picker("Repair with", selection: Binding(get: { model.selectedBackendID ?? "" }, set: { model.selectedBackendID = $0 })) {
                    ForEach(model.backends) { backend in
                        Text(backend.name).tag(backend.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("repair.model")
            }
            .hvCard()
        } else if model.needsModel {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Text("No model is connected yet. Connect one in Chat, then come back and try again.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                Button("Open Chat") {
                    dismiss()
                    app.router.open(.tab(.chat))
                }
                .buttonStyle(.hvGhost)
            }
        }
    }

    private var explanation: String {
        if let renderError, !renderError.isEmpty {
            return "A coding model will look at the error the page actually hit and try to fix its cause so the page renders. It won't finish half-built features; it just gets the page to load."
        }
        return "A coding model will try to fix syntax errors, like an unbalanced brace or an unclosed tag, so the page renders. It won't finish half-built features; it just gets the page to load."
    }

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .running:
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HStack(spacing: HV.Space.xs) { ProgressView(); Text("Repairing").font(.hvCallout.weight(.semibold)) }
                Text("This can take up to a minute for a big page. It keeps going if you close this.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        case .done(let changed, let message):
            Label(message, systemImage: changed ? "checkmark.circle.fill" : "info.circle.fill").hvRowLabel()
                .font(.hvCallout)
                .foregroundStyle(changed ? Palette.success : Palette.textSecondary)
        case .failed(let message, let needsBackend):
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                ArtifactErrorLine(message: message)
                if needsBackend {
                    Button("Open Chat") {
                        dismiss()
                        app.router.open(.tab(.chat))
                    }
                    .buttonStyle(.hvGhost)
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: HV.Space.xs) {
            switch model.phase {
            case .done(let changed, _) where changed:
                Button("Open the page") {
                    onRepaired()
                    dismiss()
                }
                .buttonStyle(.hvPrimary)
            default:
                Button(model.phase == .running ? "Repairing" : "Attempt repair") { start() }
                    .buttonStyle(.hvPrimary)
                    .disabled(model.phase == .running || model.needsModel)
            }
        }
        .padding(HV.Space.m)
        .background(Palette.background)
    }

    private func start() {
        Task {
            await model.run(renderError: renderError)
            if case .done(let changed, _) = model.phase, changed { Haptics.success() }
            if case .failed = model.phase { Haptics.failure() }
        }
    }
}
