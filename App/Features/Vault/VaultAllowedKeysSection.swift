import HyperVaultKit
import SwiftUI

/// "Allowed keys": one switch per agent key, bound to what the server last said (handoff 4.6). A tap sends the request and
/// puts a spinner where the switch was; the switch comes back where the server says it is, whatever the answer. No switch
/// is drawn until both reads have answered, so none ever stands for a state nobody confirmed.
struct VaultAllowedKeysSection: View {
    let allowed: VaultAllowedKeysModel
    let secret: VaultSecret
    let onConnect: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Section {
            switch allowed.phase {
            case .loading:
                HStack(spacing: HV.Space.s) {
                    ProgressView()
                    Text(VaultCopy.loadingLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Label(message, systemImage: "exclamationmark.circle").hvRowLabel()
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.danger)
                    Button(VaultScreenCopy.tryAgainLabel) { Task { await allowed.load(name: secret.name) } }
                        .buttonStyle(.hvGhost)
                        .padding(.leading, -HV.Space.s)
                }
            case .ready(let keys, _):
                if keys.isEmpty {
                    VStack(alignment: .leading, spacing: HV.Space.s) {
                        Text(VaultCopy.noAgentKeysLine)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                        Button(VaultScreenCopy.connectAnAgentLabel, action: onConnect)
                            .buttonStyle(.hvGhost)
                            .padding(.leading, -HV.Space.s)
                    }
                } else {
                    ForEach(keys) { key in switchRow(key) }
                    if let message = allowed.changeError { KeysInlineMessage(text: message) }
                }
            }
        } header: {
            HVSectionHeader(title: VaultCopy.allowedKeysHeading)
        } footer: {
            Text(VaultCopy.allowedKeysLine).hvSectionNote()
        }
        .hvListRow()
    }

    @ViewBuilder
    private func switchRow(_ key: AgentKey) -> some View {
        if allowed.isPending(key.id) {
            // A spinner in the switch's place: a UISwitch moves its thumb when it is tapped, before the answer, and a
            // setter that changes nothing would leave it showing an allow nobody has confirmed.
            HStack(spacing: HV.Space.s) {
                keyLabel(key)
                Spacer(minLength: HV.Space.s)
                ProgressView()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(key.allowSwitchLabel)
            .accessibilityValue(VaultScreenCopy.savingSwitchValue)
        } else {
            Toggle(
                isOn: Binding(
                    get: { allowed.isAllowed(key.id) },
                    set: { on in Task { await allowed.setAllowed(on, keyID: key.id, name: secret.name) } }
                )
            ) {
                keyLabel(key)
            }
            .accessibilityLabel(key.allowSwitchLabel)
        }
    }

    /// The prefix first, in monospace, then the key's name unless it is "default". At accessibility sizes the name goes
    /// under the prefix, so neither is squeezed into a sliver beside the switch.
    private func keyLabel(_ key: AgentKey) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: HV.Space.xs))
        return layout {
            Text(key.prefixLabel).font(.system(.footnote, design: .monospaced))
            if let name = key.displayName {
                Text(name).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
        }
    }
}
