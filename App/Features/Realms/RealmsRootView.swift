import HyperVaultKit
import SwiftUI

private enum RealmsDestination: Hashable {
    case realm(String)
}

/// Domain, a pane of the You tab: claim you.vault.cool (or another address from the portfolio), give each one a look and a
/// home page, and see what Pro includes. Payment happens on the web: the upgrade page opens in Safari. The
/// native version of the web's Domain pane and /upgrade, and of the look each address wears.
struct RealmsRootView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var model: RealmsModel?
    @State private var webPage: KeysWebPage?
    @State private var claiming = false
    @State private var showsPlans = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                HVLoadingState().frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle(AccountPane.domain.label)
        .keysLargeTitle()
        .navigationDestination(for: RealmsDestination.self) { destination in
            if let model {
                switch destination {
                case .realm(let id): RealmDetailView(claimID: id, model: model)
                }
            }
        }
        .task {
            if model == nil { model = RealmsModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id) }
            await model?.load()
        }
        .navigationDestination(isPresented: $claiming) {
            if let model { ClaimRealmView(model: model) }
        }
        .sheet(item: $webPage) { page in
            KeysSafariSheet(url: page.url).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func content(_ model: RealmsModel) -> some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 3).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded:
            list(model)
        }
    }

    private var maxClaims: Int { env.limits.maxProSubdomains }

    private func list(_ model: RealmsModel) -> some View {
        List {
            if model.isStale {
                Section { HVStaleBanner().listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }

            Section {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    Text(RealmPlanCopy.domainLine)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    claimButton(model)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xl, trailing: HV.Space.m))
            }

            Section(header: HVSectionHeader(title: "Your addresses", detail: model.claims.isEmpty ? nil : "\(model.claims.count) of \(maxClaims)")) {
                if model.claims.isEmpty {
                    noAddresses
                } else {
                    ForEach(model.claims) { claim in
                        NavigationLink(value: RealmsDestination.realm(claim.id)) {
                            RealmRow(claim: claim, isPro: model.snapshot.isPro)
                        }
                        .accessibilityIdentifier("realms.row.\(claim.id)")
                    }
                }
            }
            .hvListRow()

            planSection(model)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    /// The same shape as "No keys yet" on Account & keys: what is missing, then what to do about it.
    private var noAddresses: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(RealmPlanCopy.noAddressTitle).font(.hvHeadline)
            Text(RealmPlanCopy.noAddressDetail)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, HV.Space.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func claimButton(_ model: RealmsModel) -> some View {
        let atLimit = model.claims.count >= maxClaims
        Button {
            claiming = true
        } label: {
            Text(model.claims.isEmpty ? "Claim an address" : "Claim another (\(model.claims.count)/\(maxClaims))")
        }
        .buttonStyle(.hvPrimary)
        .disabled(atLimit)
        if atLimit {
            KeysInlineMessage(text: "Pro accounts can hold up to \(maxClaims) subdomains, and you've claimed them all.", isError: false)
        }
    }

    // MARK: Plan

    private func planSection(_ model: RealmsModel) -> some View {
        Section(header: HVSectionHeader(title: "Plan")) {
            HStack {
                Text("Your plan").font(.hvBody)
                Spacer()
                if model.snapshot.isPro { HVTag(text: "Pro", tint: Palette.blue) } else { HVTag(text: "Free") }
            }
            .accessibilityElement(children: .combine)

            // Not a DisclosureGroup: its chevron is drawn bold in the primary colour, heavier than the muted
            // ones on every other row. This is the same row with the same quiet chevron.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showsPlans.toggle() }
            } label: {
                HStack {
                    Text("What Pro includes").font(.hvBody).foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: HV.Space.xs)
                    KeysChevron(isOpen: showsPlans)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsPlans ? "Expanded" : "Collapsed")
            .accessibilityHint(showsPlans ? "Hides the plans" : "Shows what Free and Pro include")

            if showsPlans {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    planColumn(title: "Free", price: RealmPlanCopy.freePrice, features: RealmPlanCopy.freeFeatures, tint: Palette.textSecondary)
                    planColumn(title: "Pro", price: RealmPlanCopy.proPrice, features: RealmPlanCopy.proFeatures, tint: Palette.blue)
                }
                .padding(.vertical, HV.Space.xs)
            }

            if !model.snapshot.isPro {
                Button {
                    webPage = KeysWebPage(env.webURL("/upgrade"))
                } label: {
                    HVRow(symbol: "safari", tint: Palette.blue, title: "See plans on the web", subtitle: RealmPlanCopy.upgradeDetail) { KeysChevron() }
                }
            }
        }
        .hvListRow()
    }

    private func planColumn(title: String, price: String, features: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.hvHeadline).foregroundStyle(tint)
                Text(price).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(tint).accessibilityHidden(true)
                    Text(feature).font(.hvFootnote).foregroundStyle(Palette.textPrimary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: Row

struct RealmRow: View {
    let claim: RealmClaim
    let isPro: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 36

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        KeysRowLayout {
            HVIconBadge(symbol: "globe", tint: Palette.blue, size: min(tile, 56))
        } words: {
            VStack(alignment: .leading, spacing: 2) {
                // An address is one word: it shrinks to fit before it is allowed to break in the middle.
                Text(claim.host)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(isLarge ? 0.5 : 0.75)
                Text(subtitle).font(.hvFootnote).foregroundStyle(Palette.textSecondary).lineLimit(isLarge ? nil : 2)
                if isLarge, isPro { HVTag(text: "Pro", tint: Palette.blue).padding(.top, 2) }
            }
        } trailing: {
            if isPro { HVTag(text: "Pro", tint: Palette.blue) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let look = claim.theme.flatMap { id in env.capabilities.themes.first { $0.id == id }?.name } ?? "Default look"
        return claim.defaultArtifactSlug == nil ? look : "\(look) \u{00B7} opens a page"
    }
}

#if DEBUG
enum RealmsPreviewData {
    static var capabilities: Capabilities {
        let json = """
        {"domains":[
          {"domain":"vault.cool","tagline":"The legendary original. you.vault.cool","featured":true,"available":true},
          {"domain":"agentvault.cloud","tagline":"For agents with their heads in the cloud","available":true},
          {"domain":"cleon.wiki","tagline":"For knowledge bases and living documents","available":true},
          {"domain":"inkbound.ink","tagline":"For stories, zines, and beautiful writing","available":true},
          {"domain":"later.example","tagline":"Not open yet","available":false}],
         "themes":[
          {"id":"modern-dark","name":"Modern Dark","mode":"dark"},
          {"id":"glassmorphism","name":"Glassmorphism","mode":"dark"},
          {"id":"newsprint","name":"Newsprint","mode":"light"},
          {"id":"memory-vault","name":"Memory Vault","mode":"light"}]}
        """
        return (try? HVCoding.decoder().decode(Capabilities.self, from: Data(json.utf8))) ?? Capabilities()
    }

    static let routes: [MockRoute] = [
        .json(.get, "/rest/v1/profiles", #"[{"plan":"pro","vanity_subdomain":"nova"}]"#),
        .json(.get, "/rest/v1/domain_claims", #"[{"id":"c1","subdomain":"nova","base_domain":"vault.cool","theme":"glassmorphism","default_artifact_slug":"my-page","claimed_at":"2026-10-01T10:00:00Z"},{"id":"c2","subdomain":"nova","base_domain":"cleon.wiki","theme":null,"default_artifact_slug":null,"claimed_at":"2026-10-02T10:00:00Z"}]"#),
        .json(.get, "/rest/v1/artifacts", #"[{"slug":"my-page","title":"My page","type":"html","visibility":"public"},{"slug":"notes","title":"Notes","type":"html","visibility":"private"},{"slug":"cv","title":"CV","type":"html","visibility":"public"}]"#),
        .json(.get, "/api/claim-domain", #"{"available":true}"#),
        .json(.post, "/api/claim-domain", #"{"domain":"nova.inkbound.ink","url":"https://nova.inkbound.ink","claimed":3,"max_subdomains":10,"message":"nova.inkbound.ink is yours, effective immediately."}"#),
        .json(.patch, "/api/claim-domain", #"{"domain":"nova.vault.cool","theme":"newsprint","message":"ok"}"#),
    ]
}

#Preview("Your address") {
    PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmsRootView() }
}

#Preview("Your address, none yet") {
    PreviewHost(
        routes: [.json(.get, "/rest/v1/profiles", #"[{"plan":"free","vanity_subdomain":null}]"#), .json(.get, "/rest/v1/domain_claims", "[]"), .json(.get, "/rest/v1/artifacts", "[]")],
        capabilities: RealmsPreviewData.capabilities
    ) { RealmsRootView() }
}
#endif
