import Foundation

/// Canned server answers shaped like the real routes, for previews and snapshot tests.
enum Fixtures {
    static let yours = """
    {"recent":[
      {"id":"a1","kind":"page","name":"Bakery landing page","summary":"","updated_at":"2026-10-25T21:02:03Z","last_opened_at":"2026-10-26T00:40:00Z","href":"/a/bakery-landing-page-x1"},
      {"id":"m1","kind":"memory","name":"Co-parenting schedule","summary":"Handoffs on Wednesday and every other weekend.","updated_at":"2026-10-24T10:00:00Z","last_opened_at":null,"href":"/vault/memory?open=m1"},
      {"id":"k1","kind":"key","name":"OPENAI_API_KEY","summary":"2 agents allowed","updated_at":"2026-10-20T10:00:00Z","last_opened_at":null,"href":"/vault/account"}
    ],
    "results":[
      {"id":"a1","kind":"page","name":"Bakery landing page","summary":"","updated_at":"2026-10-25T21:02:03Z","last_opened_at":"2026-10-26T00:40:00Z","href":"/a/bakery-landing-page-x1"},
      {"id":"m1","kind":"memory","name":"Co-parenting schedule","summary":"Handoffs on Wednesday and every other weekend.","updated_at":"2026-10-24T10:00:00Z","last_opened_at":null,"href":"/vault/memory?open=m1"},
      {"id":"k1","kind":"key","name":"OPENAI_API_KEY","summary":"2 agents allowed","updated_at":"2026-10-20T10:00:00Z","last_opened_at":null,"href":"/vault/account"},
      {"id":"g1","kind":"group","name":"Portfolio site","summary":"","updated_at":"2026-10-12T10:00:00Z","last_opened_at":null,"href":"/g/portfolio-site"},
      {"id":"a2","kind":"page","name":"Trip to Lisbon","summary":"","updated_at":"2026-09-30T10:00:00Z","last_opened_at":null,"href":"/a/trip-to-lisbon-q7"}
    ]}
    """

    static let backends = #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic","default_model":"claude-opus","key_hint":"sk-…abcd","created_at":"2026-10-01T00:00:00Z","last_used_at":null}],"providers":[]}"#
    static let noBackends = #"{"backends":[],"providers":[]}"#
}
