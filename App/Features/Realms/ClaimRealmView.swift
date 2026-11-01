import HyperVaultKit
import SwiftUI

/// Pick a base domain from the portfolio, pick a name, see at once whether it is free, and claim it. A claim
/// takes effect immediately (the server routes the host as soon as it exists). 403 is the Pro limit and 409 is
/// "taken"; both arrive with the server's own sentence. Source: components/domain-picker.tsx.
struct ClaimRealmView: View {
    let model: RealmsModel

    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private struct Query: Equatable {
        var name: String
        var base: String
    }

    @State private var flow: RealmClaimFlow
    @State private var base = ""
    @State private var name = ""
    @State private var webPage: KeysWebPage?
    @FocusState private var nameFocused: Bool
    /// Claiming replaces the page, and the button VoiceOver was on with it.
    @AccessibilityFocusState private var celebrationFocused: Bool

    init(model: RealmsModel) {
        self.model = model
        _flow = State(initialValue: RealmClaimFlow(
            checkName: { name, base in try await model.availability(name: name, base: base) },
            claimName: { name, base in try await model.claim(name: name, base: base) }
        ))
    }

    private var portfolio: [Capabilities.PortfolioDomain] { RealmRules.ordered(env.capabilities.domains) }

    private var chosenBase: String {
        if !base.isEmpty { return base }
        return portfolio.first(where: \.available)?.domain ?? "vault.cool"
    }

    var body: some View {
        ScrollView {
            if let claimed = flow.claimed {
                celebration(claimed)
            } else {
                picker
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if flow.claimed == nil { claimBar }
        }
        .hvScreenBackground()
        .navigationTitle("Claim an address")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webPage) { page in KeysSafariSheet(url: page.url).ignoresSafeArea() }
        // Debounced live availability: each change restarts the wait, and a stale answer is dropped.
        .task(id: Query(name: name, base: chosenBase)) { await flow.check(name: name, base: chosenBase) }
    }

    // MARK: Picking

    private var picker: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Text("Pick your name").font(.hvHeadline)
                // The domain sits beside the field while they fit and under it when they do not, so neither
                // is squeezed at the largest text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HV.Space.xs) {
                        nameField
                        domainSuffix
                    }
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        nameField
                        domainSuffix
                    }
                }
                availabilityLine
                    .frame(minHeight: 20, alignment: .leading)
                if let failure = flow.failure { KeysInlineMessage(text: failure) }
            }

            VStack(alignment: .leading, spacing: HV.Space.s) {
                Text("Where it lives").font(.hvHeadline)
                Text(RealmPlanCopy.pickLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                ForEach(portfolio) { domain in
                    domainCard(domain)
                }
            }
        }
        .padding(HV.Space.m)
        .hvReadableWidth()
    }

    private var nameField: some View {
        TextField("Address name", text: $name, prompt: Text.hvPrompt("nova"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .submitLabel(.done)
            .focused($nameFocused)
            .onChange(of: name) { _, value in
                let lowered = value.lowercased()
                if lowered != value { name = lowered }
                flow.failure = nil
            }
            .hvFieldChrome(isFocused: nameFocused)
    }

    private var domainSuffix: some View {
        Text(".\(chosenBase)")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// The one filled action, pinned where the thumb is, so it is there whatever the portfolio's length.
    private var claimBar: some View {
        Button {
            Task { await flow.claim(name: name, base: chosenBase) }
        } label: {
            if flow.claiming { ProgressView().tint(.white) } else { Text("Claim my address") }
        }
        .buttonStyle(.hvPrimary)
        .disabled(flow.availability != .available || flow.claiming)
        .accessibilityHint(flow.availability == .available ? "" : "Pick a name that is free first.")
        .hvActionBar()
    }

    private func domainCard(_ domain: Capabilities.PortfolioDomain) -> some View {
        let selected = chosenBase == domain.domain
        return Button {
            guard domain.available else { return }
            Haptics.select()
            base = domain.domain
        } label: {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        HVAddressText(domain.domain).font(.system(.body, design: .monospaced, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: HV.Space.xs)
                        domainTags(domain)
                    }
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        HVAddressText(domain.domain).font(.system(.body, design: .monospaced, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                        HStack { domainTags(domain) }
                    }
                }
                if !domain.tagline.isEmpty {
                    Text(domain.tagline).font(.hvFootnote).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.leading)
                }
                if domain.available {
                    HStack(spacing: HV.Space.xs) {
                        Text("\(name.isEmpty ? "you" : name).\(domain.domain)")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(selected ? Palette.textPrimary : Palette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        // The chosen card is a step up in paper and carries a check: the one mark, never colour alone.
                        if selected {
                            Spacer(minLength: HV.Space.xs)
                            // The size of the preview line beside it, so choosing a card does not make it taller.
                            HVIcon(HVSymbol.selected).font(.system(.footnote, weight: .bold)).foregroundStyle(Palette.textPrimary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HV.Space.m)
            .background(selected ? Palette.surfaceRaised : Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous)
                    .strokeBorder(selected ? Palette.controlBorder : Palette.border, lineWidth: 1)
            )
            .opacity(domain.available ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!domain.available)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(domain.available ? "Choose this domain" : "Not open yet")
    }

    @ViewBuilder
    private func domainTags(_ domain: Capabilities.PortfolioDomain) -> some View {
        if domain.featured { HVTag(text: "Featured", tint: Palette.blue) }
        if !domain.available { HVTag(text: "Coming soon") }
    }

    @ViewBuilder
    private var availabilityLine: some View {
        let preview = "\(name).\(chosenBase)"
        switch flow.availability {
        case .idle:
            Text("Your address will live at \(name.isEmpty ? "you" : name).\(chosenBase)")
                .font(.hvFootnote).foregroundStyle(Palette.textSecondary)
        case .checking:
            HStack(spacing: HV.Space.xs) { ProgressView().controlSize(.small); Text("Checking \(preview)...").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
        case .available:
            Label("\(preview) is available", systemImage: "checkmark.circle.fill").font(.hvFootnote).foregroundStyle(Palette.success)
        case .unavailable(let reason):
            Text(reason).font(.hvFootnote).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Done

    private func celebration(_ result: ClaimResult) -> some View {
        VStack(spacing: HV.Space.l) {
            // The seal a kept thing gets (`ChatKeptNoteView`, the Home card): flat mint, no gradient.
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(Palette.mint)
                .accessibilityHidden(true)
            VStack(spacing: HV.Space.xs) {
                Text("\(result.domain) is yours")
                    .font(.hvTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($celebrationFocused)
                Text(result.message ?? "It is live now.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                if let count = result.claimed, let max = result.maxSubdomains {
                    Text("\(count) of \(max) addresses claimed. Your whole vault lives on every one.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
            VStack(spacing: HV.Space.s) {
                Button("Visit it") { webPage = KeysWebPage(URL(string: result.url ?? "https://\(result.domain)")) }
                    .buttonStyle(.hvPrimary)
                Button("Done") { dismiss() }.buttonStyle(.hvSecondary)
            }
        }
        .padding(HV.Space.xl)
        .hvReadableWidth()
        .task { celebrationFocused = true }
    }
}

#if DEBUG
#Preview("Claim") {
    PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { ClaimPreview() }
}

private struct ClaimPreview: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: RealmsModel?

    var body: some View {
        Group {
            if let model { ClaimRealmView(model: model) } else { HVLoadingState() }
        }
        .task { model = RealmsModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id) }
    }
}
#endif
