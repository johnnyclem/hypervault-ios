import Foundation
import HyperVaultKit
import Observation

/// Something that can wear a kit. The app's is `StyleRuntime`; a test passes one that records what it was asked to wear.
protocol StyleWearer: AnyObject {
    /// Wears `kit`, or the app's own default look for nil.
    func wear(_ kit: StyleKit?)
}

extension StyleRuntime: StyleWearer {
    func wear(_ kit: StyleKit?) { apply(kit) }
}

/// The look the app is wearing, and the one decision about it that belongs to the phone.
///
/// The person's theme is on the server (`profiles.theme`), and the server derives the accessible kit for it. This holds what
/// the server last said (`DashboardThemeState`, from the disk first and then the network), decides whether the app wears it,
/// and tells the runtime. It is owned by `AppModel`, not by the signed-in environment: it has to wear the cached look before
/// the environment exists, and be emptied on every way a session ends.
///
///   * The phone's switch, "Use this theme in the app" (default on, `PrefKey.styleKitInApp`), only decides whether the app
///     wears a kit it has. The website keeps the theme either way.
///   * A theme with no kit (`retro`, a server that sends none, a kit this build cannot read or that fails the floors) is the
///     default look, and `look` says so, so the pane can.
///   * The runtime is told only when what is worn changes. A refresh that brought the same answer repaints nothing.
///   * An answer that was overtaken (a newer choice was made, or the session ended, while it was on its way) is dropped, and is
///     not written to the cache either.
@MainActor
@Observable
final class StyleKitStore {
    /// The `UserDefaults` key of the phone's switch (`PrefKey.styleKitInApp`).
    nonisolated static let appliesToAppKey = "pref.styleKit.inApp"

    /// What the app is wearing, as the pane says it.
    enum Look: Equatable {
        /// No theme is chosen (or the stored one has left the catalog): the app's own look.
        case standard
        /// The theme is worn. `adjusted` is true when the server moved a colour the person can see as the theme's.
        case worn(name: String, adjusted: Bool)
        /// The theme has a kit and the phone's switch is off.
        case off(name: String)
        /// The theme is chosen and there is no kit to wear for it: the app keeps its own look.
        case withheld(themeID: String)

        var isWorn: Bool {
            if case .worn = self { return true }
            return false
        }
    }

    /// What the server last said about the person's theme, from the disk or the network. Nil before either has answered.
    private(set) var state: DashboardThemeState?
    private(set) var look: Look = .standard
    /// Whether the app wears a theme it has a kit for.
    private(set) var appliesToApp: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let wearer: any StyleWearer
    @ObservationIgnored private let now: () -> Date
    /// The kit the wearer was last asked to wear, so it is asked again only when that changes.
    @ObservationIgnored private var wornKit: StyleKit?
    /// Bumps when the session ends or the person chooses, so an answer that was in flight for the old state can tell.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var lastAsked: Date?

    init(defaults: UserDefaults = .standard, wearer: any StyleWearer = StyleRuntime.shared, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.wearer = wearer
        self.now = now
        appliesToApp = defaults.object(forKey: Self.appliesToAppKey) as? Bool ?? true
    }

    // MARK: The phone's switch

    /// Sets "Use this theme in the app" and wears or drops the theme at once.
    func setAppliesToApp(_ on: Bool) {
        guard on != appliesToApp else { return }
        defaults.set(on, forKey: Self.appliesToAppKey)
        appliesToApp = on
        update()
    }

    // MARK: Reading the look

    /// The look on disk for this person, if there is one: no network, so the first frame after launch can wear it.
    func preload(cache: DiskCache, userID: String) async {
        let epoch = self.epoch
        guard let cached = await StyleKitLoader.cached(in: cache, userID: userID) else { return }
        // Something newer has happened since the read began (a choice, a sign-out): the disk copy is the old news.
        guard epoch == self.epoch else { return }
        adopt(cached)
    }

    /// Asks the server, wears the answer and keeps it on disk. A failure throws and leaves whatever is worn as it was.
    func refresh(using loader: StyleKitLoader) async throws {
        let epoch = self.epoch
        lastAsked = now()
        let fresh = try await loader.fetch()
        guard epoch == self.epoch else { return }
        adopt(fresh)
        await loader.remember(fresh)
    }

    /// `refresh`, if the last ask was long enough ago: the theme is most often changed on the website, and the app follows it
    /// when it comes to the front. A failure is not worth a word: the look stays as it is.
    func refreshIfStale(using loader: StyleKitLoader, after interval: TimeInterval = 15 * 60) async {
        if let lastAsked, now().timeIntervalSince(lastAsked) < interval { return }
        try? await refresh(using: loader)
    }

    /// Wears a state the server just returned, the answer to a `PATCH`, and keeps it on disk. It is the newest news, so
    /// anything still on its way is the old.
    func keep(_ saved: DashboardThemeState, using loader: StyleKitLoader) async {
        epoch += 1
        lastAsked = now()
        adopt(saved)
        await loader.remember(saved)
    }

    /// The session has ended: the look goes back to the app's own, and what was in flight is dropped. The disk copy is the
    /// cache's to wipe (`DiskCache.clear(namespace:)`), which every way a session ends does.
    func reset() {
        epoch += 1
        lastAsked = nil
        state = nil
        look = .standard
        wear(nil)
    }

    // MARK: Wearing

    /// Takes a state as the one to wear. The same state again changes nothing.
    func adopt(_ next: DashboardThemeState) {
        guard next != state else { return }
        state = next
        update()
    }

    private func update() {
        guard let state, let theme = state.theme else {
            look = .standard
            wear(nil)
            return
        }
        guard let kit = state.kit else {
            look = state.isWithheld ? .withheld(themeID: theme) : .standard
            wear(nil)
            return
        }
        guard appliesToApp else {
            look = .off(name: kit.name)
            wear(nil)
            return
        }
        look = .worn(name: kit.name, adjusted: kit.hasNoticeableAdjustments)
        wear(kit)
    }

    private func wear(_ kit: StyleKit?) {
        guard kit != wornKit else { return }
        wornKit = kit
        wearer.wear(kit)
    }
}
