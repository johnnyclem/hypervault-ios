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

    private enum Availability: Equatable {
        case idle
        case checking
        case available
        case unavailable(String)
    }

    private struct Query: Equatable {
        var name: String
        var base: String
    }

    @State private var base = ""
    @State private var name = ""
    @State private var availability = Availability.idle
    @State private var claiming = false
    @State private var failure: String?
    @State private var claimed: ClaimResult?
    @State private var webPage: KeysWebPage?
    @FocusState private var nameFocused: Bool

    private var portfolio: [Capabilities.PortfolioDomain] { RealmRules.ordered(env.capabilities.domains) }

    private var chosenBase: String {
        if !base.isEmpty { return base }
        return portfolio.first(where: \.available)?.domain ?? "vault.cool"
    }

    var body: some View {
        ScrollView {
            if let claimed {
                celebration(claimed)
            } else {
                picker
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if claimed == nil { claimBar }
        }
        .hvScreenBackground()
        .navigationTitle("Claim an address")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $webPage) { page in KeysSafariSheet(url: page.url).ignoresSafeArea() }
        // Debounced live availability: each change restarts the wait, and a stale answer is dropped.
        .task(id: Query(name: name, base: chosenBase)) { await checkAvailability() }
    }

    // MARK: Picking

    private var picker: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Text("Pick your name").font(.hvHeadline)
                HStack(spacing: HV.Space.xs) {
                    TextField("nova", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onChange(of: name) { _, value in
                            let lowered = value.lowercased()
                            if lowered != value { name = lowered }
                            failure = nil
                        }
                        .hvFieldChrome(isFocused: nameFocused)
                    Text(".\(chosenBase)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                availabilityLine
                    .frame(minHeight: 20, alignment: .leading)
                if let failure { KeysInlineMessage(text: failure) }
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

    /// The one filled action, pinned where the thumb is, so it is there whatever the portfolio's length.
    private var claimBar: some View {
        VStack(spacing: HV.Space.xs) {
            Button {
                Task { await claim() }
            } label: {
                if claiming { ProgressView().tint(.white) } else { Text("Claim my address") }
            }
            .buttonStyle(.hvPrimary)
            .disabled(availability != .available || claiming)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.top, HV.Space.s)
        .padding(.bottom, HV.Space.s)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func domainCard(_ domain: Capabilities.PortfolioDomain) -> some View {
        let selected = chosenBase == domain.domain
        return Button {
            guard domain.available else { return }
            Haptics.select()
            base = domain.domain
        } label: {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HStack {
                    Text(domain.domain).font(.system(.body, design: .monospaced, weight: .semibold)).foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: HV.Space.xs)
                    if domain.featured { HVTag(text: "Featured", tint: Palette.blue) }
                    if !domain.available { HVTag(text: "Coming soon") }
                }
                if !domain.tagline.isEmpty {
                    Text(domain.tagline).font(.hvFootnote).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.leading)
                }
                if domain.available {
                    Text("\(name.isEmpty ? "you" : name).\(domain.domain)")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(selected ? Color.accentColor : Palette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HV.Space.m)
            .background(selected ? Color.accentColor.opacity(0.1) : Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Palette.border, lineWidth: selected ? 1.5 : 1)
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
    private var availabilityLine: some View {
        let preview = "\(name).\(chosenBase)"
        switch availability {
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

    // MARK: Checking and claiming

    private func checkAvailability() async {
        let current = name
        let base = chosenBase
        guard !current.isEmpty else { availability = .idle; return }
        switch RealmRules.validate(current) {
        case .failure(let problem):
            availability = .unavailable(problem.message)
            return
        case .success(let valid):
            availability = .checking
            // Wait for a pause in typing; a change cancels this task before the request goes out.
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            do {
                let answer = try await model.availability(name: valid, base: base)
                if Task.isCancelled { return }
                availability = answer.available ? .available : .unavailable(answer.reason ?? "That name is taken.")
            } catch {
                // Rate limited or a hiccup: stay quiet, claiming still validates.
                if !Task.isCancelled { availability = .idle }
            }
        }
    }

    private func claim() async {
        guard case .success(let valid) = RealmRules.validate(name) else { return }
        claiming = true
        failure = nil
        defer { claiming = false }
        do {
            claimed = try await model.claim(name: valid, base: chosenBase)
            Haptics.success()
        } catch {
            failure = keysMessage(for: error)
            Haptics.failure()
        }
    }

    // MARK: Done

    private func celebration(_ result: ClaimResult) -> some View {
        VStack(spacing: HV.Space.l) {
            Image(systemName: "party.popper.fill")
                .font(.system(size: 52))
                .foregroundStyle(Palette.brandGradient)
                .accessibilityHidden(true)
            VStack(spacing: HV.Space.xs) {
                Text("\(result.domain) is yours").font(.hvTitle).multilineTextAlignment(.center)
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
    }
}

#if DEBUG
#Preview("Claim") {
    KeysPreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { ClaimPreview() }
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
