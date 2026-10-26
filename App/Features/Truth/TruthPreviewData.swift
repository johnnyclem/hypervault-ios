#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for previews and snapshots: lines from stenographer's own
/// fixtures, in the envelopes the routes use.
enum TruthPreviewData {
    static let tb1 = #"{"id":"01M1E6JK80P9Y3CMA9HBZEND9H","type":"TB","ts":"2026-09-01T10:00:00.000Z","author":"johnnyclem","claim":"LOG_BUDGET is 100; the old value 30 is dead.","evidence":[{"kind":"commit","ref":"9f2c1ab"},{"kind":"claimed-command","ref":"grep LOG_BUDGET config.ts","detail":"LOG_BUDGET = 100"}],"signedBy":"johnnyclem","answerableBy":"johnnyclem","status":"active"}"#
    static let tb2 = #"{"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","type":"TB","ts":"2026-09-01T10:52:00.000Z","author":"johnnyclem","claim":"Retries are capped at 5; the old cap of 3 is dead.","evidence":[{"kind":"test","ref":"test/retry.test.ts"}],"signedBy":"johnnyclem","answerableBy":"johnnyclem","status":"active"}"#
    static let uv1 = #"{"id":"01M1E6JK81TR57BA191BG8Y0Q3","type":"UV","ts":"2026-09-01T10:01:00.000Z","author":"agent:Claude Code","assertion":"Retries are idempotent across regions.","basis":"the design doc says so","verifyBy":{"kind":"inspect","value":"src/retry.ts","detail":"a region-scoped idempotency key"},"status":"open"}"#
    static let uv2 = #"{"id":"01M1E6JK82QWPK6VS437JKMJPZ","type":"UV","ts":"2026-09-01T10:02:00.000Z","author":"alex","assertion":"LOG_BUDGET went back to 30 in the hotfix.","basis":"the hotfix notes","verifyBy":{"kind":"command","value":"grep LOG_BUDGET config.ts"},"contests":"01M1E6JK80P9Y3CMA9HBZEND9H","status":"open"}"#
    static let uvRefuted = #"{"id":"01M1E6JK8RY2RTGX9TRXJABTWR","type":"UV","ts":"2026-09-01T10:51:00.000Z","author":"sam","assertion":"Each retry costs 20.","basis":"the pricing doc","verifyBy":{"kind":"inspect","value":"pricing.md"},"status":"refuted"}"#

    static let ledgers = #"{"default":"default","ledgers":[{"id":"l2","slug":"default","name":"Default","kind":"mirror","created_at":"2026-09-01T10:00:00.000Z","proposals_seq":0},{"id":"l1","slug":"team","name":"Team","kind":"hosted","created_at":"2026-10-01T10:00:00.000Z","proposals_seq":4}]}"#

    static var overview: String {
        """
        {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},
         "summary":{"cited":2,"contested":1,"flags":1,"displaced":1,"total":4,"open_proposals":3},
         "as_of":"2026-10-25T12:00:00.000Z","chat_truth":true,"sidecar":{"configured":false,"notary":false},
         "docket":{"size":3,"nominated":1,"stale":1,"as_of":"2026-10-25T12:00:00.000Z","oldest_age_ms":172800000},
         "review":{"cadence":"weekly","last_at":"2026-10-18T12:00:00.000Z","due":true,"next_at":"2026-10-25T12:00:00.000Z"},
         "citable":[
           {"entry":\(tb1),"standing":"sound","reasons":[],"answerable_by":"johnnyclem","contested_by":[\(uv2)]},
           {"entry":\(tb2),"standing":"clouded","reasons":[{"premise":"01M1E6JK81TR57BA191BG8Y0Q3","reason":"premise-open"}],"answerable_by":"johnnyclem","contested_by":[]}],
         "flags":[\(uv1)],
         "displaced":[\(uvRefuted)],
         "entries":[
           {"id":"01M1E6JK80P9Y3CMA9HBZEND9H","type":"TB","status":"contested","standing":"sound","reasons":[],"corroborated":false,"freshness":null,"answerable_by":"johnnyclem","author":"johnnyclem","ts":"2026-09-01T10:00:00.000Z","source":"manual"},
           {"id":"01M1E6JK81TR57BA191BG8Y0Q3","type":"UV","status":"open","standing":"sound","reasons":[],"corroborated":true,"freshness":{"state":"stale","horizonSeconds":1814400,"since":"2026-09-01T10:01:00.000Z","at":"2026-10-25T12:00:00.000Z","expiresAt":"2026-09-22T10:01:00.000Z"},"answerable_by":null,"author":"agent:Claude Code","ts":"2026-09-01T10:01:00.000Z","source":"manual"},
           {"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","type":"TB","status":"active","standing":"clouded","reasons":[{"premise":"01M1E6JK81TR57BA191BG8Y0Q3","reason":"premise-open"}],"corroborated":false,"freshness":null,"answerable_by":"johnnyclem","author":"johnnyclem","ts":"2026-09-01T10:52:00.000Z","source":"manual"},
           {"id":"01M1E6JK8RY2RTGX9TRXJABTWR","type":"UV","status":"refuted","standing":"sound","reasons":[],"corroborated":false,"freshness":null,"answerable_by":null,"author":"sam","ts":"2026-09-01T10:51:00.000Z","source":"manual"}]}
        """
    }

    static var derivation: String {
        """
        {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},"id":"01M1E6JK8SQAJ8K0JBRHTD10YG",
         "derivation":{"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","type":"TB","status":"active","standing":"clouded",
           "reasons":[{"premise":"01M1E6JK81TR57BA191BG8Y0Q3","reason":"premise-open"}],
           "text":"Retries are capped at 5; the old cap of 3 is dead.","signedBy":"johnnyclem","answerableBy":"johnnyclem",
           "premises":[
             {"id":"01M1E6JK81TR57BA191BG8Y0Q3","type":"UV","status":"open","standing":"sound","reasons":[],"text":"Retries are idempotent across regions.","premises":[],"kind":"derives","failing":"premise-open"},
             {"id":"01M1E6JK8QHST8RZF45PNRBMXG","type":"TB","status":"active","standing":"sound","reasons":[],"text":"The retry budget is 100.","signedBy":"johnnyclem","answerableBy":"johnnyclem","premises":[],"kind":"derives"}]},
         "dependents":[{"id":"01M1E6JK8T990YNBMTS1KP26ZW","type":"UV","status":"open","standing":"clouded","reasons":[{"premise":"01M1E6JK81TR57BA191BG8Y0Q3","reason":"premise-open","via":"01M1E6JK8SQAJ8K0JBRHTD10YG"}],"signedBy":null,"answerableBy":null,"text":"The per-tenant cap is 5 too."}]}
        """
    }

    static let ripple = #"{"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","roots":[],"missing":[],"entries":[{"id":"01M1E6JK8T990YNBMTS1KP26ZW","type":"UV","status":"open","standing":"clouded","reasons":[],"text":"The per-tenant cap is 5 too.","depth":1,"via":"01M1E6JK8SQAJ8K0JBRHTD10YG"}],"context":[{"kind":"memory","id":"mem1","item":{"kind":"memory","id":"mem1","title":"Retry policy, as of October"},"relation":"rests_on","entry_id":"01M1E6JK8SQAJ8K0JBRHTD10YG","affected":true,"stale":false,"stale_kind":null,"note":null}],"counts":{"entries":1,"context":1,"affected":1,"stale":0}}"#

    static var docket: String {
        """
        {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},
         "docket":{"items":[
          {"kind":"uv","id":"01M1E6JK81TR57BA191BG8Y0Q3","subject":"x","text":"Retries are idempotent across regions.","author":"agent:Claude Code","agentSessionId":"sess-1",
           "createdAt":"2026-10-23T12:00:00.000Z","ageMs":172800000,"nominated":true,"suspect":false,"stale":true,
           "freshness":{"state":"stale","horizonSeconds":1814400,"since":"2026-09-01T10:00:00.000Z","at":"2026-10-25T12:00:00.000Z","expiresAt":"2026-09-22T10:00:00.000Z"},
           "deferredUntil":null,"status":"open","standing":"clouded","evidence":[],"basis":"the design doc says so",
           "verifyBy":{"kind":"inspect","value":"src/retry.ts","detail":"a region-scoped idempotency key"},"contests":null,"line":{},
           "approvals":{"approvers":1,"human":false,"agentSessions":1,"nominated":true,"missing":["a human approval"],
             "list":[{"by":"agent:Claude Code","role":"agent","agent_session_id":"sess-1","evidence":[{"kind":"commit","ref":"9f2c1ab","detail":"adds the key"}],"note":"checked it","created_at":"2026-10-24T12:00:00.000Z"}]},
           "derivation":{"id":"x","type":"UV","status":"open","standing":"clouded","reasons":[{"premise":"P1","reason":"premise-open"}],"text":"Retries are idempotent across regions.","premises":[{"id":"01M1E6JK8QHST8RZF45PNRBMXG","type":"UV","status":"open","standing":"sound","reasons":[],"text":"Regions share one store.","premises":[],"kind":"derives","failing":"premise-open"}]}},
          {"kind":"appeal","id":"01M1E6JK80P9Y3CMA9HBZEND9H","subject":"x","text":"LOG_BUDGET is 100; the old value 30 is dead.","author":"johnnyclem","createdAt":"2026-10-25T08:00:00.000Z","ageMs":14400000,
           "nominated":false,"suspect":false,"stale":false,"status":"contested","standing":"sound","evidence":[{"kind":"commit","ref":"9f2c1ab"}],"line":{},
           "appeals":{"status":"contested","contestedBy":[{"id":"01M1E6JK82QWPK6VS437JKMJPZ","assertion":"LOG_BUDGET went back to 30 in the hotfix.","author":"alex"}]},"derivation":null},
          {"kind":"migration","id":"22222222-2222-4222-8222-222222222222","subject":"page:ledger","text":"Retries stop at 5, not 3.","author":"detector:hypervault-migration",
           "createdAt":"2026-10-25T10:00:00.000Z","ageMs":7200000,"nominated":false,"suspect":false,"stale":false,"status":"open","evidence":[],"line":{},
           "migration":{"page":{"slug":"retry-ledger","line_id":"L7","owner":"gpt-4"},"literal":{"dead":"3","current":"5"},"proposalId":"22222222-2222-4222-8222-222222222222"},"derivation":null}],
          "size":3,"nominated":1,"stale":1,"asOf":"2026-10-25T12:00:00.000Z"},
         "review":{"cadence":"weekly","last_at":"2026-10-18T12:00:00.000Z","due":true,"next_at":"2026-10-25T12:00:00.000Z"}}
        """
    }

    static var ledgerRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/ledgers", ledgers),
            .json(.get, "/api/truth", overview),
        ]
    }

    static var emptyRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/ledgers", ledgers),
            .json(.get, "/api/truth", #"{"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},"summary":{"cited":0,"contested":0,"flags":0,"displaced":0,"total":0,"open_proposals":0},"chat_truth":true,"citable":[],"flags":[],"displaced":[],"entries":[]}"#),
        ]
    }

    static var reviewRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/ledgers", ledgers),
            .json(.get, "/api/truth/review", docket),
            .json(.get, "/api/truth/signers", #"{"signers":[{"id":"johnnyclem","role":"human"},{"id":"agent:Claude Code","role":"agent"}]}"#),
            .json(.get, "/api/rooms", #"{"rooms":[{"id":"r1","title":"Ops room","pending":0,"members":[]}]}"#),
            .json(.post, "/api/truth/review", #"{"ok":true}"#),
        ]
    }

    static var entryRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/01M1E6JK8SQAJ8K0JBRHTD10YG/derivation", derivation),
            .json(.get, "/api/truth/01M1E6JK8SQAJ8K0JBRHTD10YG/ripple", ripple),
        ]
    }

    static var draftRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/proposals", #"{"proposals":[{"id":"p1","kind":"tombstone","target_ref":"t","origin":"chat-compaction","status":"open","created_at":"2026-10-20T10:00:00.000Z","line":{"kind":"tb","draft":{"claim":"The old retry cap no longer holds.","evidence":[{"kind":"commit","ref":"abc123"}]},"signal":{"source":"compaction-candidate","detail":"Said twice in chat"}}},{"id":"p2","kind":"uv","target_ref":"u","origin":"api","status":"open","created_at":"2026-10-21T10:00:00.000Z","line":{"kind":"uv","draft":{"assertion":"Writes are idempotent.","basis":"The docs say so","verifyBy":{"kind":"inspect","value":"src/retry.ts"}},"signal":{"source":"compaction-candidate"}}}]}"#),
        ]
    }

    static var noticeRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/events", #"{"events":[{"id":"e1","entry_id":"01M1E6JK8SQAJ8K0JBRHTD10YG","entry_type":"TB","kind":"undermined","prior_status":"active","new_status":"active","by_entry_id":"01M1E6JK8QHST8RZF45PNRBMXG","by_author":"kim","summary":"TB 01M1E6JK8SQAJ8K0JBRHTD10YG is unsupported: a premise beneath it was struck.","created_at":"2026-10-24T10:00:00.000000+00:00"},{"id":"e2","entry_id":"01M1E6JK81TR57BA191BG8Y0Q3","entry_type":"UV","kind":"verified","prior_status":"open","new_status":"verified","by_entry_id":null,"by_author":null,"summary":"UV 01M1E6JK81TR57BA191BG8Y0Q3 was verified.","created_at":"2026-10-23T09:00:00.000000+00:00"}],"kinds":[]}"#),
        ]
    }

    static var staleRoutes: [MockRoute] {
        [
            .json(.get, "/api/truth/stale", #"{"ledger":null,"items":[{"item":{"kind":"memory","id":"mem1","title":"Retry policy, as of October"},"key":"memory:mem1","ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},"edges":[{"link":{"entry_id":"E1","relation":"rests_on","seen_status":"active","seen_standing":"sound","stale_since":"2026-10-24T10:00:00.000Z","stale_kind":"overturned","stale_by":null,"stale_summary":"The retry cap TB was overridden by a newer one.","note":null},"entry":{"id":"E1","type":"TB","status":"overridden","standing":"sound","reasons":[],"text":"Retries are capped at 3.","signedBy":"johnnyclem","answerableBy":"johnnyclem"},"successor":{"id":"E9","type":"TB","status":"active","standing":"sound","reasons":[],"text":"Retries are capped at 5; the old cap of 3 is dead.","signedBy":"johnnyclem","answerableBy":"johnnyclem"}}]}],"total":1,"as_of":"2026-10-25T12:00:00.000Z"}"#),
        ]
    }

    static var signerRoutes: [MockRoute] {
        [.json(.get, "/api/truth/signers", #"{"signers":[{"id":"johnnyclem","role":"human"},{"id":"agent:Claude Code","role":"agent"},{"id":"agent:Gemini","role":"agent"}]}"#)]
    }
}
#endif
