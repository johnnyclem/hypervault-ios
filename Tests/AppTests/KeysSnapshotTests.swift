import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// Agent keys, the Connect sheet, webhooks, the vault and Your address, rendered in light and
/// dark on canned routes. CI publishes the PNGs to `snapshots-claude-ios-keys`.
@MainActor
final class KeysSnapshotTests: XCTestCase {
    func testAccountAndKeys() throws {
        try snapshot(PreviewHost(routes: KeysPreviewData.routes) { AgentsAndKeysView() }, named: "keys-account")
    }

    func testAccountAndKeysWithNoKeys() throws {
        try snapshot(PreviewHost(routes: [.json(.get, "/rest/v1/api_keys", "[]")]) { AgentsAndKeysView() }, named: "keys-account-empty")
    }

    func testKeyDetail() throws {
        try snapshot(PreviewHost(routes: KeysPreviewData.routes) { KeyDetailSnapshotHost() }, named: "keys-detail")
    }

    func testConnectPicker() throws {
        try snapshot(PreviewHost(embedInNavigation: false) { ConnectAgentSheet() }, named: "keys-connect-picker")
    }

    func testConnectWithAKey() throws {
        try snapshot(
            PreviewHost(routes: ConnectPreviewData.routes, embedInNavigation: false) { ConnectReadyPreview(clientID: "cursor") },
            named: "keys-connect-ready",
            size: CGSize(width: 393, height: 2400),
            settle: 1.5
        )
    }

    func testLargestTextSizes() throws {
        let accessibility = DynamicTypeSize.accessibility3
        try snapshot(
            PreviewHost(routes: KeysPreviewData.routes) { AgentsAndKeysView() }.environment(\.dynamicTypeSize, accessibility),
            named: "keys-account-large"
        )
        try snapshot(
            PreviewHost(routes: KeysPreviewData.routes) { KeyDetailSnapshotHost() }.environment(\.dynamicTypeSize, accessibility),
            named: "keys-detail-large",
            size: CGSize(width: 393, height: 1400)
        )
        try snapshot(
            PreviewHost(embedInNavigation: false) { ConnectAgentSheet() }.environment(\.dynamicTypeSize, accessibility),
            named: "keys-connect-picker-large"
        )
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes) { VaultItemsView() }.environment(\.dynamicTypeSize, accessibility),
            named: "vault-list-large"
        )
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview() }.environment(\.dynamicTypeSize, accessibility),
            named: "vault-add-choose-large",
            size: CGSize(width: 393, height: 1400)
        )
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .card) }.environment(\.dynamicTypeSize, accessibility),
            named: "vault-add-card-large",
            size: CGSize(width: 393, height: 2000)
        )
        try snapshot(
            PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmsRootView() }.environment(\.dynamicTypeSize, accessibility),
            named: "realms-large",
            size: CGSize(width: 393, height: 1400)
        )
        try snapshot(
            PreviewHost(routes: [.json(.get, "/api/webhooks", WebhooksSnapshotData.json)]) { WebhooksView() }.environment(\.dynamicTypeSize, accessibility),
            named: "keys-webhooks-large"
        )
    }

    func testWebhooks() throws {
        try snapshot(PreviewHost(routes: [.json(.get, "/api/webhooks", WebhooksSnapshotData.json)]) { WebhooksView() }, named: "keys-webhooks")
    }

    func testWebhookDetail() throws {
        let routes: [MockRoute] = [
            .json(.get, "/api/webhooks/w1", WebhooksSnapshotData.detail),
            .json(.get, "/api/webhooks", WebhooksSnapshotData.json),
        ]
        try snapshot(
            PreviewHost(routes: routes) { WebhookDetailPreview(hookID: "w1") },
            named: "keys-webhook-detail",
            size: CGSize(width: 393, height: 1100)
        )
    }

    func testAddAWebhook() throws {
        try snapshot(
            PreviewHost(routes: [.json(.get, "/api/webhooks", WebhooksSnapshotData.json)], embedInNavigation: false) { WebhookAddPreview() },
            named: "keys-webhooks-add",
            size: CGSize(width: 393, height: 1100)
        )
    }

    func testVault() throws {
        try snapshot(PreviewHost(routes: VaultPreviewData.routes) { VaultItemsView() }, named: "vault-list")
    }

    func testVaultEmpty() throws {
        try snapshot(PreviewHost(routes: [.json(.get, "/api/secrets", #"{"secrets":[]}"#)]) { VaultItemsView() }, named: "vault-empty")
    }

    func testVaultLoginDetail() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "github.com") },
            named: "vault-detail-login",
            size: CGSize(width: 393, height: 1500)
        )
    }

    func testVaultCardDetail() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "visa-4242") },
            named: "vault-detail-card",
            size: CGSize(width: 393, height: 1500)
        )
    }

    /// The grants list cannot be read: no switches, a plain sentence and a way to try again. The server's own
    /// words are a bare status line here, and must not show.
    func testVaultDetailWhenTheGrantsCannotBeRead() throws {
        let routes = [MockRoute.failure(.get, "/api/secrets/visa-4242/grants", status: 500, message: "Internal Server Error")] + VaultPreviewData.routes
        try snapshot(
            PreviewHost(routes: routes) { VaultEntryPreview(name: "visa-4242") },
            named: "vault-detail-grants-failed",
            size: CGSize(width: 393, height: 1500)
        )
    }

    func testVaultRename() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultChangePreview(name: "github.com") },
            named: "vault-edit"
        )
    }

    func testVaultReplaceACard() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultChangePreview(name: "visa-4242", replacing: true) },
            named: "vault-replace-card",
            size: CGSize(width: 393, height: 1300)
        )
    }

    func testVaultAddChoose() throws {
        try snapshot(PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview() }, named: "vault-add-choose")
    }

    func testVaultAddCard() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .card) },
            named: "vault-add-card",
            size: CGSize(width: 393, height: 1300)
        )
    }

    func testVaultAddLogin() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .login) },
            named: "vault-add-login",
            size: CGSize(width: 393, height: 1100)
        )
    }

    func testVaultAddContact() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .contact) },
            named: "vault-add-contact",
            size: CGSize(width: 393, height: 1200)
        )
    }

    func testVaultAddKey() throws {
        try snapshot(
            PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .opaque) },
            named: "vault-add-key",
            size: CGSize(width: 393, height: 1000)
        )
    }

    func testRealms() throws {
        try snapshot(
            PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmsRootView() },
            named: "realms"
        )
    }

    func testRealmsNoneYet() throws {
        let routes: [MockRoute] = [
            .json(.get, "/rest/v1/profiles", #"[{"plan":"free","vanity_subdomain":null}]"#),
            .json(.get, "/rest/v1/domain_claims", "[]"),
            .json(.get, "/rest/v1/artifacts", "[]"),
        ]
        try snapshot(PreviewHost(routes: routes, capabilities: RealmsPreviewData.capabilities) { RealmsRootView() }, named: "realms-none")
    }

    func testRealmDetailAtLargestText() throws {
        try snapshot(
            PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmDetailSnapshotHost() }
                .environment(\.dynamicTypeSize, .accessibility3),
            named: "realms-detail-large",
            size: CGSize(width: 393, height: 1500)
        )
    }

    func testRealmDetail() throws {
        try snapshot(
            PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmDetailSnapshotHost() },
            named: "realms-detail"
        )
    }

    func testClaimARealm() throws {
        try snapshot(
            PreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { ClaimSnapshotHost() },
            named: "realms-claim"
        )
    }
}

// MARK: Hosts that load a model first

private struct KeyDetailSnapshotHost: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: AgentsAndKeysModel?

    var body: some View {
        Group {
            if let model { KeyDetailView(keyID: "k1", model: model) } else { HVLoadingState() }
        }
        .task {
            let loaded = AgentsAndKeysModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id)
            await loaded.load()
            model = loaded
        }
    }
}

private struct RealmDetailSnapshotHost: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: RealmsModel?

    var body: some View {
        Group {
            if let model { RealmDetailView(claimID: "c1", model: model) } else { HVLoadingState() }
        }
        .task {
            let loaded = RealmsModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id)
            await loaded.load()
            model = loaded
        }
    }
}

private struct ClaimSnapshotHost: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: RealmsModel?

    var body: some View {
        Group {
            if let model { ClaimRealmView(model: model) } else { HVLoadingState() }
        }
        .task { model = RealmsModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id) }
    }
}

private enum WebhooksSnapshotData {
    static let detail = #"""
    {"webhook":{"id":"w1","name":"grok","url":"https://agent.example/hooks/hv","events":["truth.challenged","truth.overturned"],"authors":["grok"],"enabled":true,"consecutive_failures":0,"last_delivered_at":"2026-10-25T10:00:00Z","last_status":200,"created_at":"2026-10-20T10:00:00Z"},
     "deliveries":[{"id":"d1","status":"delivered","attempts":1,"last_status":200,"last_error":null,"created_at":"2026-10-25T10:00:00Z","delivered_at":"2026-10-25T10:00:01Z"},
                   {"id":"d2","status":"failed","attempts":5,"last_status":502,"last_error":"Bad gateway","created_at":"2026-10-24T10:00:00Z","delivered_at":null}]}
    """#

    static let json = #"""
    {"webhooks":[{"id":"w1","name":"grok","url":"https://agent.example/hooks/hv","events":["truth.challenged","truth.overturned"],"authors":["grok"],"enabled":true,"consecutive_failures":0,"last_delivered_at":"2026-10-25T10:00:00Z","last_status":200,"created_at":"2026-10-20T10:00:00Z"},
     {"id":"w2","name":"","url":"https://hooks.example.org/in","events":["truth.*"],"authors":[],"enabled":true,"consecutive_failures":3,"last_delivered_at":null,"last_status":502,"created_at":"2026-10-21T10:00:00Z"}],
     "events":["truth.*","truth.challenged","truth.overturned","truth.upheld","truth.verified","truth.undermined","truth.restored"]}
    """#
}
