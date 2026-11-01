import HyperVaultKit
import SwiftUI

/// Whether the quiet Home page shows the first-run card that asks for one thing: give an agent a key (the web's
/// `ConnectAgentCard`). It shows only when everything it depends on is known:
///
/// - the person has no agent key (the keys list was read, fresh, and was empty), and
/// - "I'll look around first" has not been chosen, on this phone or on the profile (`onboarding.connect_dismissed_at`,
///   which the web writes too, so a dismissal made there carries over).
///
/// Until the keys have loaded, and when they cannot be loaded, it shows nothing: a card that flashes on and then goes
/// away, or asks someone who has a key to make one, is worse than none. There is no "Agent connected" or "Setup pending"
/// state here, since no route reports the server's check of that (HANDOFF decision 6).
@MainActor
@Observable
final class ConnectCardModel {
    private(set) var isVisible = false
    /// A look has finished, whatever it found. Until then the card may still turn up, so the hints above it hold back
    /// their own Connect button rather than draw it and take it away again.
    private(set) var hasLooked = false

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let rest: AccountRest
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let defaults: UserDefaults
    /// The person has a key or has dismissed the card: nothing a later look could change before the app is opened again.
    @ObservationIgnored private var isSettled = false

    init(client: HVClient, rest: AccountRest, userID: String, defaults: UserDefaults = .standard) {
        self.client = client
        self.rest = rest
        self.userID = userID
        self.defaults = defaults
    }

    /// Where this phone remembers that this person chose "I'll look around first". Per person, so another account
    /// signing in on the same phone is asked on its own.
    static func memoryKey(userID: String) -> String { "hv.connectCardDismissed.\(userID)" }

    private var memoryKey: String { Self.memoryKey(userID: userID) }

    /// Whether this phone remembers the dismissal.
    var isDismissedHere: Bool { defaults.bool(forKey: memoryKey) }

    /// Looks again at whether the card is wanted. Called when the page appears, when the Connect sheet closes and when
    /// the person comes back to Home, since a key made meanwhile ends the card. A look that fails leaves the card off
    /// and is made again at the next of those.
    func refresh() async {
        guard !isSettled else { return }
        if isDismissedHere {
            settle()
            return
        }
        do {
            let keys = try await AgentKeyDirectory.keys(rest: rest, userID: userID)
            guard keys.isEmpty else {
                settle()
                return
            }
            // Only a person with no key is asked whether they chose to look around, on any device.
            let onboarding = try await rest.onboarding(userID: userID)
            if onboarding.connectDismissed {
                defaults.set(true, forKey: memoryKey)
                settle()
                return
            }
            // A dismissal, or a key found by a look that finished meanwhile, wins over these reads.
            isVisible = !isSettled && !isDismissedHere
            hasLooked = true
        } catch is CancellationError {
            return
        } catch HVError.cancelled {
            // The page went away mid-read; what it showed is still the best there is.
            return
        } catch {
            isVisible = false
            hasLooked = true
        }
    }

    /// "I'll look around first". The card goes and the phone remembers at once; the profile is told after, so the
    /// card does not come back while the request is in flight or if it fails. The returned task is the request.
    @discardableResult
    func dismiss() -> Task<Void, Never> {
        defaults.set(true, forKey: memoryKey)
        isVisible = false
        isSettled = true
        hasLooked = true
        let client = self.client
        return Task { _ = await ConnectOnboarding.recordDismissed(client: client) }
    }

    private func settle() {
        isSettled = true
        isVisible = false
        hasLooked = true
    }
}

/// The card: a title, one line, "Connect an agent" and a quiet way out.
struct ConnectCard: View {
    var onConnect: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            KeysRowLayout {
                // The key's own tile, as on a key card: this is a Home card, where the kind colour lives.
                HVIconBadge(symbol: HVSymbol.key, tint: KeptKind.key.tint, size: 36)
            } words: {
                Text(ConnectCardCopy.title)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(ConnectCardCopy.line)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: HV.Space.xxs) {
                Button(ConnectCardCopy.connectLabel, action: onConnect)
                    .buttonStyle(.hvPrimary)
                    .accessibilityIdentifier("canvas.connectCard.connect")
                Button(ConnectCardCopy.dismissLabel, action: onDismiss)
                    .buttonStyle(.hvGhost)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("canvas.connectCard.dismiss")
            }
        }
        .hvCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.connectCard")
    }
}

/// Where the card sits on the quiet page, under the hints, and it takes no room at all while the card is off. The page
/// holds the model, so the hints above can leave out their own Connect button while the card is the one asking; the slot
/// makes the model once there is an account to ask about.
struct ConnectCardSlot: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    @Binding var model: ConnectCardModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model, model.isVisible {
                ConnectCard(
                    onConnect: { app.router.sheet = .connectAgent },
                    onDismiss: { HV.Motion.animate(HV.Motion.sheet) { _ = model.dismiss() } }
                )
                .padding(.horizontal, HV.Space.xl)
                .padding(.top, HV.Space.m)
                .padding(.bottom, HV.Space.l)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .task {
            if model == nil {
                model = ConnectCardModel(client: env.client, rest: env.keysRest, userID: env.user.id)
            }
            await model?.refresh()
        }
        // A key made in the Connect sheet ends the card as the sheet closes.
        .onChange(of: app.router.sheet) { old, new in
            if old == .connectAgent, new == nil { Task { await model?.refresh() } }
        }
        // So does one made under You, by the time the person is back on Home.
        .onChange(of: app.router.tab) { _, tab in
            if tab == .canvas { Task { await model?.refresh() } }
        }
    }
}
