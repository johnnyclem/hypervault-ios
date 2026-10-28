import HyperVaultKit
import SwiftUI

/// Makes one of the person's addresses open on this page instead of the list of
/// their public pages. One page per address; tapping the address that already
/// opens on this page sets it back.
struct ArtifactRealmHomeSheet: View {
    let detail: ArtifactDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var changing: String?
    @State private var warning: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(detail.realms) { realm in
                        Button { toggle(realm) } label: { row(realm) }
                            .buttonStyle(.plain)
                            .disabled(changing != nil)
                    }
                } footer: {
                    Text("The address opens straight on this page, with no list of your pages. Its link to this page still works.")
                }
                .hvListRow()
                if let warning {
                    Section { Label(warning, systemImage: "exclamationmark.triangle.fill").hvRowLabel().font(.hvFootnote).foregroundStyle(Palette.warning) }
                        .hvListRow()
                }
                if let error {
                    Section { ArtifactErrorLine(message: error).listRowBackground(Color.clear) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Home page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func row(_ realm: ArtifactRealm) -> some View {
        let isHome = realm.defaultArtifactSlug == detail.slug
        return HStack(spacing: HV.Space.s) {
            HVIconBadge(symbol: HVSymbol.domain, tint: Palette.blue, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HVAddressText(realm.host).font(.hvBody).foregroundStyle(Palette.textPrimary)
                Text(isHome ? "Opens on this page" : (realm.defaultArtifactSlug == nil ? "Opens on your list of public pages" : "Opens on another page"))
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: HV.Space.xs)
            if changing == realm.host {
                ProgressView()
            } else if isHome {
                HVIcon("checkmark").foregroundStyle(.tint).fontWeight(.semibold)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHome ? .isSelected : [])
    }

    private func toggle(_ realm: ArtifactRealm) {
        let makeHome = realm.defaultArtifactSlug != detail.slug
        changing = realm.host
        warning = nil
        error = nil
        Task {
            defer { changing = nil }
            do {
                let result = try await detail.env.client.send(
                    .setRealmHome(subdomain: realm.subdomain, baseDomain: realm.baseDomain, slug: makeHome ? detail.slug : nil)
                )
                warning = result.warning
                app.toasts.show(result.message.isEmpty ? (makeHome ? "Done." : "Back to your list of public pages.") : result.message, style: .success)
                await detail.refreshRealms()
            } catch {
                self.error = ArtifactErrors.message(error)
                Haptics.failure()
            }
        }
    }
}
