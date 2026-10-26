import HyperVaultKit
import SwiftUI

/// Who has a page and what they can do with it. Reads who has it when the
/// sheet opens, adds a person by email with a role, and removes one.
@MainActor
@Observable
final class ArtifactShareModel {
    private(set) var list: ArtifactLoad<ArtifactShareList> = .loading
    /// False when the server says the page is not the person's to share (a 404).
    private(set) var canManage = true
    private(set) var pending = false
    private(set) var error: String?

    private let client: HVClient
    private let slug: String

    init(client: HVClient, slug: String) {
        self.client = client
        self.slug = slug
    }

    func load() async {
        do {
            list = .loaded(try await client.send(.artifactShares(slug: slug)))
            canManage = true
        } catch let error as HVError where error.isNotFound {
            // Not the owner's, so not theirs to share: the link is all this sheet offers.
            canManage = false
            list = .failed(error.userMessage)
        } catch {
            list = .failed(ArtifactErrors.message(error))
        }
    }

    /// Gives a person a role. Returns the sentence to show when it went through.
    func add(email: String, role: ArtifactShareRole) async -> String? {
        pending = true
        error = nil
        defer { pending = false }
        do {
            let added = try await client.send(.shareArtifact(slug: slug, email: email, role: role))
            // The answer to an add has no share id to remove it by: read the list again.
            await load()
            return added.message
        } catch {
            self.error = ArtifactErrors.message(error)
            return nil
        }
    }

    func remove(_ person: ArtifactSharePerson) async -> Bool {
        guard case .loaded(let current) = list else { return false }
        pending = true
        error = nil
        defer { pending = false }
        // Gone from the list at once; back if the server says no.
        list = .loaded(ArtifactShareList(people: current.people.filter { $0.id != person.id }, roles: current.roles, enforced: current.enforced))
        do {
            _ = try await client.send(.endShare(id: person.id))
            return true
        } catch {
            list = .loaded(current)
            self.error = ArtifactErrors.message(error)
            return false
        }
    }
}

/// The share sheet: the page's link to hand to anyone, and the people who can open it.
struct ArtifactShareSheet: View {
    let detail: ArtifactDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model: ArtifactShareModel
    @State private var host: String?
    @State private var email = ""
    @State private var chosenRole: ArtifactShareRole?
    @State private var removing: ArtifactSharePerson?
    @FocusState private var emailFocused: Bool

    init(detail: ArtifactDetailModel) {
        self.detail = detail
        _model = State(initialValue: ArtifactShareModel(client: detail.env.client, slug: detail.slug))
        _host = State(initialValue: detail.defaultHost)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.l) {
                    linkSection
                    if model.canManage { peopleSection }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                removing.map { "Remove \($0.name)?" } ?? "",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { person in
                Button("Remove", role: .destructive) { remove(person) }
            } message: { _ in
                Text("They will no longer be able to open it.")
            }
        }
        .task { await model.load() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Link

    private var url: URL { detail.link(host: host) }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVSectionHeader(title: "Link").artifactCardCaption()
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                // Cut in the middle rather than wrapped: at an accessibility size a long address broken into pieces of
                // eight characters, with a hyphen drawn at each break, is harder to read than one with its middle left out
                // (the whole of it is what the buttons below copy and share, and what a long press selects).
                Text(url.absoluteString)
                    .font(.hvMono)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let line = linkLine {
                    Text(line).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
                if !detail.realms.isEmpty {
                    Divider()
                    HStack {
                        Text("Link from").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Picker("Link from", selection: $host) {
                            Text(detail.env.server.baseURL.host ?? "HyperVault").tag(String?.none)
                            ForEach(detail.realms) { realm in
                                Text(realm.host).tag(String?.some(realm.host))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
            .hvCard()

            ShareLink(item: url, subject: Text(detail.title), preview: SharePreview(detail.title)) {
                Label("Share link", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.hvPrimary)

            Button {
                ArtifactPasteboard.copy(url.absoluteString)
                Haptics.tap()
                app.toasts.show(LibraryCopy.linkCopied, style: .info)
            } label: {
                Label(LibraryCopy.copyLink, systemImage: "doc.on.doc")
            }
            .buttonStyle(.hvSecondary)
        }
    }

    /// What the link does for whoever gets it.
    private var linkLine: String? {
        switch detail.visibility {
        case .private: return "Private. It opens for you and the people you add below."
        case .password: return "Behind a password. Anyone who has one can open it."
        case .public: return "Public. Anyone with the link can open it."
        case nil: return nil
        }
    }

    // MARK: People

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVSectionHeader(title: LibraryCopy.sharePeople).artifactCardCaption()
            switch model.list {
            case .loading:
                HVLoadingState()
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }
            case .loaded(let list):
                addForm(list)
                if let error = model.error { ArtifactErrorLine(message: error) }
                if !list.people.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(list.people.enumerated()), id: \.element.id) { index, person in
                            if index > 0 { Divider().padding(.leading, 56) }
                            personRow(person, list: list)
                        }
                    }
                    .hvCard(padding: 0)
                }
            }
            Text(LibraryCopy.shareFooter)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .artifactCardCaption()
        }
    }

    @ViewBuilder
    private func addForm(_ list: ArtifactShareList) -> some View {
        let roles = list.offeredRoles
        let role = chosenRole.flatMap { roles.contains($0) ? $0 : nil } ?? roles.first
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVLabeledField(title: LibraryCopy.shareEmail) {
                TextField(LibraryCopy.shareEmail, text: $email, prompt: artifactPrompt("name@example.com"))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($emailFocused)
                    .onSubmit { add(role: role) }
            }
            if roles.count > 1, let role {
                // Wraps, so three roles stay whole at the largest sizes; each is 44 points to hit.
                ArtifactFlowLayout(spacing: HV.Space.xs) {
                    ForEach(roles, id: \.self) { option in
                        Button { chosenRole = option; Haptics.select() } label: {
                            HVChip(title: option.title, isSelected: option == role)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == role ? .isSelected : [])
                    }
                }
            }
            if let role {
                Text(role.line).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            Button(LibraryCopy.shareAdd) { add(role: role) }
                .buttonStyle(.hvSecondary)
                .disabled(!ArtifactShareEmail.isValid(email) || role == nil || model.pending)
        }
    }

    private func personRow(_ person: ArtifactSharePerson, list: ArtifactShareList) -> some View {
        HStack(spacing: HV.Space.s) {
            HVAvatar(name: person.name, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.hvBody).lineLimit(1)
                Text(list.effectiveRole(of: person).title)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: HV.Space.xs)
            // A removal asks first, and the ghost style draws a destructive role in the danger colour.
            Button(LibraryCopy.shareRemove, role: .destructive) { removing = person }
                .buttonStyle(.hvGhost)
                .disabled(model.pending)
                .accessibilityLabel("Remove \(person.name)")
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove") { removing = person }
    }

    private func add(role: ArtifactShareRole?) {
        guard let role, ArtifactShareEmail.isValid(email), !model.pending else { return }
        let address = email
        Task {
            if let message = await model.add(email: address, role: role) {
                email = ""
                app.toasts.show(message, style: .success)
            } else {
                Haptics.failure()
            }
        }
    }

    private func remove(_ person: ArtifactSharePerson) {
        Task {
            if await model.remove(person) { app.toasts.show("Access removed.", style: .success) } else { Haptics.failure() }
        }
    }
}
