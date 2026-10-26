import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// Account & keys, the Connect sheet, pairing, webhooks, the vault and Your address, rendered in light and
/// dark on canned routes. CI publishes the PNGs to `snapshots-claude-ios-keys`.
@MainActor
final class KeysSnapshotTests: XCTestCase {
    func testAccountAndKeys() throws {
        try snapshot(KeysPreviewHost(routes: KeysPreviewData.routes) { AgentsAndKeysView() }, named: "keys-account")
    }

    func testAccountAndKeysWithNoKeys() throws {
        try snapshot(KeysPreviewHost(routes: [.json(.get, "/rest/v1/api_keys", "[]")]) { AgentsAndKeysView() }, named: "keys-account-empty")
    }

    func testKeyDetail() throws {
        try snapshot(KeysPreviewHost(routes: KeysPreviewData.routes) { KeyDetailSnapshotHost() }, named: "keys-detail")
    }

    func testConnectPicker() throws {
        try snapshot(KeysPreviewHost(embedInNavigation: false) { ConnectAgentSheet() }, named: "keys-connect-picker")
    }

    func testConnectWithAKey() throws {
        try snapshot(
            KeysPreviewHost(routes: ConnectPreviewData.routes, embedInNavigation: false) { ConnectReadyPreview(clientID: "cursor") },
            named: "keys-connect-ready",
            settle: 1.5
        )
    }

    func testPairingAsking() throws {
        let probe: [MockRoute] = [.failure(.post, "/api/pair/poll", status: 400, message: "device_code is required")]
        try snapshot(KeysPreviewHost(routes: probe, embedInNavigation: false) { PairApprovalView(code: "BCDF-2346") }, named: "keys-pair-asking")
    }

    func testPairingEnteringACode() throws {
        let probe: [MockRoute] = [.failure(.post, "/api/pair/poll", status: 400, message: "device_code is required")]
        try snapshot(KeysPreviewHost(routes: probe, embedInNavigation: false) { PairApprovalView(code: nil) }, named: "keys-pair-enter")
    }

    func testPairingNotAvailable() throws {
        let off: [MockRoute] = [.failure(.post, "/api/pair/poll", status: 404, message: "Not found.")]
        try snapshot(KeysPreviewHost(routes: off, embedInNavigation: false) { PairApprovalView(code: "BCDF-2346") }, named: "keys-pair-unavailable")
    }

    func testWebhooks() throws {
        try snapshot(KeysPreviewHost(routes: [.json(.get, "/api/webhooks", WebhooksSnapshotData.json)]) { WebhooksView() }, named: "keys-webhooks")
    }

    func testVault() throws {
        try snapshot(KeysPreviewHost(routes: VaultPreviewData.routes) { VaultItemsView() }, named: "vault-list")
    }

    func testVaultEmpty() throws {
        try snapshot(KeysPreviewHost(routes: [.json(.get, "/api/secrets", #"{"secrets":[]}"#)]) { VaultItemsView() }, named: "vault-empty")
    }

    func testVaultLoginDetail() throws {
        try snapshot(KeysPreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "github.com") }, named: "vault-detail-login")
    }

    func testVaultCardDetail() throws {
        try snapshot(KeysPreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "visa-4242") }, named: "vault-detail-card")
    }

    func testVaultAddChoose() throws {
        try snapshot(KeysPreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview() }, named: "vault-add-choose")
    }

    func testVaultAddCard() throws {
        try snapshot(KeysPreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .card) }, named: "vault-add-card")
    }

    func testVaultAddLogin() throws {
        try snapshot(KeysPreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .login) }, named: "vault-add-login")
    }

    func testRealms() throws {
        try snapshot(
            KeysPreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmsRootView() },
            named: "realms"
        )
    }

    func testRealmsNoneYet() throws {
        let routes: [MockRoute] = [
            .json(.get, "/rest/v1/profiles", #"[{"plan":"free","vanity_subdomain":null}]"#),
            .json(.get, "/rest/v1/domain_claims", "[]"),
            .json(.get, "/rest/v1/artifacts", "[]"),
        ]
        try snapshot(KeysPreviewHost(routes: routes, capabilities: RealmsPreviewData.capabilities) { RealmsRootView() }, named: "realms-none")
    }

    func testRealmDetail() throws {
        try snapshot(
            KeysPreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { RealmDetailSnapshotHost() },
            named: "realms-detail"
        )
    }

    func testClaimARealm() throws {
        try snapshot(
            KeysPreviewHost(routes: RealmsPreviewData.routes, capabilities: RealmsPreviewData.capabilities) { ClaimSnapshotHost() },
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
    static let json = #"""
    {"webhooks":[{"id":"w1","name":"grok","url":"https://agent.example/hooks/hv","events":["truth.challenged","truth.overturned"],"authors":["grok"],"enabled":true,"consecutive_failures":0,"last_delivered_at":"2026-10-25T10:00:00Z","last_status":200,"created_at":"2026-10-20T10:00:00Z"},
     {"id":"w2","name":"","url":"https://hooks.example.org/in","events":["truth.*"],"authors":[],"enabled":true,"consecutive_failures":3,"last_delivered_at":null,"last_status":502,"created_at":"2026-10-21T10:00:00Z"}],
     "events":["truth.*","truth.challenged","truth.overturned","truth.upheld","truth.verified","truth.undermined","truth.restored"]}
    """#
}
