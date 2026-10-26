import HyperVaultKit
import SwiftUI

/// One invite code: hand it over, turn it off, or destroy it.
struct AdminInviteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AdminModel
    let inviteID: String
    let server: URL
    @State private var confirmDestroy = false

    var body: some View {
        Group {
            if let invite = model.invite(id: inviteID) {
                detail(invite)
            } else {
                HVEmptyState(symbol: "ticket", title: "Gone", message: "This code is no longer in the list.")
            }
        }
        .hvScreenBackground()
        .navigationTitle("Invite code")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ invite: AdminInvite) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text(invite.code)
                        .font(.system(.title, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                    HStack(spacing: HV.Space.xs) {
                        HVTag(text: statusLabel(invite), tint: statusTint(invite))
                        Text("\(invite.useCount) of \(invite.maxUses) used")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if let note = invite.note, !note.isEmpty {
                        Text(note).font(.hvCallout).foregroundStyle(Palette.textSecondary)
                    }
                    if let created = invite.createdAt {
                        Text("Created \(created.formatted(date: .abbreviated, time: .shortened))")
                            .font(.hvCaption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                .padding(.vertical, HV.Space.xxs)
            }

            Section(header: HVSectionHeader(title: "Hand it over")) {
                AdminCopyButton(text: invite.code, title: "Copy the code")
                ShareLink(item: invite.shareURL(server: server), message: Text("Your HyperVault invite: \(invite.code)")) {
                    Label("Share the invite link", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44, alignment: .leading)
                }
            }

            Section(
                header: HVSectionHeader(title: "Manage"),
                footer: Text("The server has no way to read a code, so the count above is as of the last time this phone asked. Check it to ask again.")
            ) {
                Toggle("Accepting new sign-ups", isOn: Binding(
                    get: { !invite.disabled },
                    set: { on in Task { await model.setDisabled(!on, inviteID: invite.id) } }
                ))
                .tint(Palette.mint)
                .disabled(model.busy.contains(invite.id))

                Button {
                    Task { await model.refresh(inviteID: invite.id) }
                } label: {
                    HStack {
                        Label("Check how many have used it", systemImage: "arrow.clockwise")
                        if model.busy.contains(invite.id) { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.busy.contains(invite.id))

                Button(role: .destructive) { confirmDestroy = true } label: {
                    Label("Destroy this code", systemImage: "trash")
                }
                .confirmationDialog("Destroy \(invite.code)?", isPresented: $confirmDestroy, titleVisibility: .visible) {
                    Button("Destroy the code", role: .destructive) {
                        Task { if await model.destroy(inviteID: invite.id) { dismiss() } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The code stops working at once and is deleted. People who already joined with it keep their access.")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func statusLabel(_ invite: AdminInvite) -> String {
        switch invite.status {
        case .active: return "Active"
        case .usedUp: return "Used up"
        case .disabled: return "Off"
        }
    }

    private func statusTint(_ invite: AdminInvite) -> Color {
        switch invite.status {
        case .active: return Palette.mint
        case .usedUp: return Palette.textSecondary
        case .disabled: return Palette.amber
        }
    }
}

#if DEBUG
#Preview("Invite") {
    PreviewHost { AdminInvitePreview() }
}

struct AdminInvitePreview: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let model = AdminModel(client: env.client, cache: env.cache, namespace: env.user.id)
        model.previewSeed()
        return AdminInviteDetailView(model: model, inviteID: "i3", server: env.server.baseURL)
    }
}
#endif
