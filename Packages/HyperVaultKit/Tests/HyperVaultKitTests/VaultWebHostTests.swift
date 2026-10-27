import XCTest
@testable import HyperVaultKit

/// `VaultItems.webHost`, the port of the part of the WHATWG URL parser that lib/secrets/items.ts runs through
/// `new URL(url)`.
///
/// The table below came from Node 22.22.0 (the engine the server runs), not from reading the standard:
///
///     const { protocol, hostname } = new URL(url);
///     return (protocol === "http:" || protocol === "https:") && hostname ? hostname : null;
///
/// Each row is an input and what that returned (`nil` for null). The inputs are the ones the audit of this port
/// found Swift got wrong in either direction (accepted what the server refuses: a `%` or `[` in the host, a port
/// over 65535, a bad IPv4 or IPv6 address, U+00A0 / U+3000 / U+0085 as a space, `xn--a`; refused what the server
/// takes: `http:example.com`, `https:\\host`, `"` and `{` in a host) and the shapes around them. The same parser was
/// also run against 600,000 random addresses and against every code point from U+0080 to U+10FFFF (see the notes
/// in VaultWebHost.swift for the one place it is knowingly looser than Node: IDNA compatibility mapping, bidi
/// and unassigned code points).
final class VaultWebHostTests: XCTestCase {
    typealias Items = VaultItems

    /// (input, hostname Node 22 gave, or nil when `new URL` threw / the scheme was not http(s) / the host was empty)
    private static let nodeTable: [(String, String?)] = [
        // an address with a plain host
        ("https://github.com/login", "github.com"),
        ("http://localhost:3000", "localhost"),
        ("https://Example.com/login", "example.com"),
        ("HTTPS://A.COM", "a.com"),
        ("Http://a.com", "a.com"),
        ("http://WWW.Example.COM:8080/x", "www.example.com"),
        ("https://u:p@a.com:80/x", "a.com"),
        ("https://a@b@c.com", "c.com"),
        ("https://@a.com", "a.com"),
        ("https://a.com:", "a.com"),
        ("https://a.com:00080", "a.com"),
        ("https://a.com:65535", "a.com"),
        ("https://a.com:0", "a.com"),
        ("https://news.ycombinator.com", "news.ycombinator.com"),
        ("https://a.com?x", "a.com"),
        ("https://a.com#x", "a.com"),
        ("https://a.com\\x", "a.com"),
        ("https://a.com/a@b", "a.com"),
        ("https://a.com:80@b.com", "b.com"),
        ("https://a.b.c.d.example", "a.b.c.d.example"),
        ("https://a_b.com", "a_b.com"),
        ("https://-a-.com", "-a-.com"),
        ("https://a..b", "a..b"),
        ("https://a.", "a."),
        ("https://.", "."),
        ("https://a--b.com", "a--b.com"),
        // the shapes of the front that new URL takes and a hand-rolled prefix check does not
        ("http:example.com", "example.com"),
        ("https:/example.com", "example.com"),
        ("https:\\\\example.com", "example.com"),
        ("http:///example.com", "example.com"),
        ("https:////example.com", "example.com"),
        ("https:/\\example.com", "example.com"),
        ("  https://a.com  ", "a.com"),
        ("https://a.com\u{A}", "a.com"),
        ("ht\u{9}tps://a.com", "a.com"),
        ("https:\u{A}//a.com", "a.com"),
        ("\u{1}https://a.com", "a.com"),
        // characters new URL leaves in a host
        ("https://a\"b.com", "a\"b.com"),
        ("https://a{b}.com", "a{b}.com"),
        ("https://a`b.com", "a`b.com"),
        ("https://a~b.com", "a~b.com"),
        ("https://a!$&'()*+,;=b.com", "a!$&'()*+,;=b.com"),
        // percent escapes are decoded before the host is judged
        ("https://%41.com", "a.com"),
        ("https://exa%C3%A9mple.com", "xn--example-dya.com"),
        ("https://%e4%be%8b.jp", "xn--fsq.jp"),
        ("https://a%C2%ADb.com", "ab.com"),
        ("https://%61%2E%63om", "a.com"),
        // IPv4 hosts
        ("https://127.0.0.1:8080/", "127.0.0.1"),
        ("https://0x7f.1", "127.0.0.1"),
        ("https://0X7F.0.0.1", "127.0.0.1"),
        ("https://0x7f.0x0.0.1", "127.0.0.1"),
        ("https://0177.0.0.1", "127.0.0.1"),
        ("https://1.2.3.4.", "1.2.3.4"),
        ("https://1.2.3.", "1.2.0.3"),
        ("https://4294967295", "255.255.255.255"),
        ("https://00", "0.0.0.0"),
        ("https://0x", "0.0.0.0"),
        ("https://1.256", "1.0.1.0"),
        ("https://1.1.65535", "1.1.255.255"),
        ("https://a.0xg", "a.0xg"),
        ("https://0x1g", "0x1g"),
        ("https://1e3", "1e3"),
        ("https://1.2.3.4a", "1.2.3.4a"),
        ("https://1.0x.1", "1.0.0.1"),
        // IPv6 hosts
        ("https://[::1]:3000/", "[::1]"),
        ("https://[0:0:0:0:0:0:0:1]", "[::1]"),
        ("https://[1:0:0:2:0:0:0:3]", "[1:0:0:2::3]"),
        ("https://[FE80::1]", "[fe80::1]"),
        ("https://[::ffff:1.2.3.4]", "[::ffff:102:304]"),
        ("https://[1:2:3:4:5:6:1.2.3.4]", "[1:2:3:4:5:6:102:304]"),
        ("https://[::]", "[::]"),
        ("https://[1::]", "[1::]"),
        ("https://[1:2:3:4:5:6:7:8]", "[1:2:3:4:5:6:7:8]"),
        ("https://[::1]:80", "[::1]"),
        // letters outside ASCII
        ("https://b\u{FC}cher.example", "xn--bcher-kva.example"),
        ("https://B\u{DC}CHER.example", "xn--bcher-kva.example"),
        ("https://\u{4F8B}\u{3048}.jp", "xn--r8jz45g.jp"),
        ("https://\u{4F8B}\u{3048}\u{3002}jp", "xn--r8jz45g.jp"),
        ("https://\u{FF45}xample.com", "example.com"),
        ("https://exa\u{AD}mple.com", "example.com"),
        ("https://exa\u{200B}mple.com", "example.com"),
        ("https://exa\u{FEFF}mple.com", "example.com"),
        ("https://\u{1F600}.com", "xn--e28h.com"),
        // zero-width joiners where spelling needs them (Node 22.22.0): Persian, Sinhala, Devanagari
        ("https://\u{6A9}\u{62A}\u{627}\u{628}\u{200C}\u{647}\u{627}.com", "xn--mgbacg1m8wy53l.com"),
        ("https://\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645}.com", "xn--mgbn2ecje63gr19l.com"),
        ("https://www.\u{DC1}\u{DCA}\u{200D}\u{DBB}\u{DD3}.lk", "www.xn--10cl1a0b660p.lk"),
        ("https://\u{915}\u{94D}\u{200D}\u{937}.com", "xn--11b2ezcw70k.com"),
        ("https://xn--mgbacg1m8wy53l.com", "xn--mgbacg1m8wy53l.com"),
        ("https://ma\u{DF}e.de", "xn--mae-6ka.de"),
        ("https://\u{130}stanbul.com", "xn--istanbul-o0e.com"),
        ("https://\u{441}\u{430}\u{439}\u{442}.\u{440}\u{444}", "xn--80aswg.xn--p1ai"),
        ("https://\u{633}\u{644}\u{627}\u{645}.com", "xn--mgbx5cf.com"),
        ("https://xn--bcher-kva.example", "xn--bcher-kva.example"),
        ("https://XN--BCHER-KVA.example", "xn--bcher-kva.example"),
        ("https://xn--a-.com", "xn--a-.com"),
        ("https://xn--ls8h.la", "xn--ls8h.la"),
        ("https://xn--80ak6aa92e.com", "xn--80ak6aa92e.com"),
        // no scheme, or not http(s), or nothing after it
        ("", nil),
        ("   ", nil),
        ("example.com", nil),
        ("github.com", nil),
        ("ftp://github.com", nil),
        ("javascript:alert(1)", nil),
        ("mailto:a@b.c", nil),
        ("//a.com", nil),
        ("https//a.com", nil),
        ("1http://a.com", nil),
        ("https://", nil),
        ("https:", nil),
        ("https:///", nil),
        ("http://:80", nil),
        ("https://@", nil),
        ("https://a@", nil),
        ("https://user:pw@", nil),
        ("https://?x", nil),
        ("https://#x", nil),
        ("https://\\", nil),
        ("https://:", nil),
        ("http://a.com:80:80", nil),
        ("ws://a.com", nil),
        ("file:///etc/passwd", nil),
        ("data:text/html,x", nil),
        // a space in the host, of any kind, however it is spelled
        ("https://exa mple.com", nil),
        ("https://exa mple.com/x", nil),
        ("http://exa mple.com:8080", nil),
        ("https://exa\u{A0}mple.com", nil),
        ("https://exa\u{3000}mple.com", nil),
        ("https://exa\u{85}mple.com", nil),
        ("https://exa\u{2028}mple.com", nil),
        ("https://exa\u{2003}mple.com", nil),
        ("https://exa\u{1680}mple.com", nil),
        ("https://exa\u{202F}mple.com", nil),
        ("https://exa%20mple.com", nil),
        ("https://exa%C2%A0mple.com", nil),
        ("https://a b.com", nil),
        ("https://a.com :80", nil),
        // characters a host may not hold
        ("https://a%b.com", nil),
        ("https://a%zz.com", nil),
        ("https://a%25b.com", nil),
        ("https://a[b.com", nil),
        ("https://a]b.com", nil),
        ("https://a^b.com", nil),
        ("https://a|b.com", nil),
        ("https://a<b.com", nil),
        ("https://a>b.com", nil),
        ("https://a%00b.com", nil),
        ("https://a%7fb.com", nil),
        ("https://%2E%2E%2F", nil),
        ("https://a%2Fb.com", nil),
        ("https://a%3Ab.com", nil),
        ("https://a%40b.com", nil),
        ("https://a%5Cb.com", nil),
        ("https://a%3Fb.com", nil),
        ("https://a%23b.com", nil),
        ("https://exa\u{FF1A}mple.com", nil),
        ("https://exa\u{FF03}mple.com", nil),
        ("https://exa\u{FF05}mple.com", nil),
        ("https://exa\u{FF20}mple.com", nil),
        // ports
        ("https://a.com:99999", nil),
        ("https://a.com:65536", nil),
        ("https://a.com:8x", nil),
        ("https://a.com:-1", nil),
        ("https://a.com:\u{664}\u{665}", nil),
        ("https://a.com: 80", nil),
        ("https://a.com:99999999999999999999", nil),
        ("https://a.com:080x", nil),
        ("https://a.com:80/x:y", "a.com"),
        ("https://[::1]:65536", nil),
        ("https://a.com:0000000000000000000080", "a.com"),
        // numbers that are not IPv4 addresses
        ("https://1.2.3.4.5", nil),
        ("https://256.1.1.1", nil),
        ("https://a.4", nil),
        ("https://1.1.65536", nil),
        ("https://4294967296", nil),
        ("https://09.1", nil),
        ("https://1..2", nil),
        ("https://123456789012", nil),
        ("https://0.0.0.256", nil),
        ("https://1.2.3.4.5.", nil),
        ("https://0x100000000", nil),
        ("https://999999999999999999999", nil),
        // bad IPv6
        ("https://[zzz]", nil),
        ("https://[::1", nil),
        ("https://[::1]x", nil),
        ("https://[1:2:3:4:5:6:7]", nil),
        ("https://[1:2:3:4:5:6:7:8:9]", nil),
        ("https://[::1::2]", nil),
        ("https://[1.2.3.4]", nil),
        ("https://[:1]", nil),
        ("https://[1:]", nil),
        ("https://[::1.2.3]", nil),
        ("https://[::256.1.1.1]", nil),
        ("https://[::01.2.3.4]", nil),
        ("https://[]", nil),
        ("https://[1:2:3:4:5:6:7::8]", nil),
        ("https://[::g]", nil),
        ("https://[12345::]", nil),
        // punycode that does not decode to a label
        ("https://xn--a.com", nil),
        ("https://xn--.com", nil),
        ("https://xn---.com", nil),
        ("https://xn--abc.com", nil),
        ("https://xn--bcher-kvb.example", nil),
        ("https://xn--zzzzzz.com", nil),
        ("https://xn--\u{E9}.com", nil),
        ("https://xn--0.com", nil),
        // letters and marks outside ASCII that no host holds
        ("https://exa\u{FFFD}mple.com", nil),
        ("https://exa\u{200D}mple.com", nil),
        ("https://exa\u{200C}mple.com", nil),
        ("https://\u{200D}example.com", nil),
        ("https://example\u{200D}.com", nil),
        ("https://\u{301}example.com", nil),
        ("https://exa\u{E000}mple.com", nil),
        ("https://exa%ffmple.com", nil),
        ("https://exa%C3mple.com", nil),
        ("https://%C2%AD", nil),
        ("https://exa\u{80}mple.com", nil),
        ("https://exa\u{200E}mple.com", nil),
        ("https://exa\u{2029}mple.com", nil),
    ]

    func testEveryRowOfTheNodeTable() {
        XCTAssertEqual(Self.nodeTable.count, 218)
        for (input, expected) in Self.nodeTable {
            XCTAssertEqual(Items.webHost(input), expected, "webHost(\(input.debugDescription))")
        }
    }

    func testTheTableHoldsBothKindsOfRow() {
        XCTAssertGreaterThan(Self.nodeTable.filter { $0.1 == nil }.count, 60)
        XCTAssertGreaterThan(Self.nodeTable.filter { $0.1 != nil }.count, 60)
    }

    // MARK: Through the login validator

    private let websiteMessage = "The website must be a full address starting with http:// or https://."

    func login(_ url: String) -> [String: String] {
        ["username": "jane", "password": "pw", "url": url]
    }

    func testAWebsiteWithASpaceInTheHostIsRefusedHoweverItIsSpelled() {
        for url in [
            "https://exa mple.com/x", "http://exa mple.com:8080", "https://exa\u{A0}mple.com", "https://exa\u{3000}mple.com",
            "https://exa\u{85}mple.com", "https://exa%20mple.com", "https://a%b.com", "https://exa%C2%A0mple.com",
        ] {
            XCTAssertEqual(Items.validate(.login, login(url)), websiteMessage, url.debugDescription)
        }
    }

    func testTheWebsitesTheServerTakesAreTaken() {
        for url in [
            "http:example.com", "https:/example.com", "https:\\\\example.com", "http:///example.com", "https://a\"b.com",
            "https://a{b}.com", "https://[::1]:3000/", "https://0x7f.1", "https://b\u{FC}cher.example", "https://\u{4F8B}\u{3048}.jp",
        ] {
            XCTAssertNil(Items.validate(.login, login(url)), url.debugDescription)
        }
    }

    func testTheWebsitesTheServerRefusesAreRefused() {
        for url in [
            "https://a.com:99999", "https://a[b.com", "https://1.2.3.4.5", "https://256.1.1.1", "https://a.4", "https://[zzz]",
            "https://xn--a.com", "ftp://a.com", "example.com", "https://",
        ] {
            XCTAssertEqual(Items.validate(.login, login(url)), websiteMessage, url.debugDescription)
        }
    }

    func testASuggestionIsNeverMadeFromASpacedHost() {
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://exa mple.com", "username": "jane"]), "jane")
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://exa%20mple.com", "username": "jane"]), "jane")
    }

    func testSuggestionsFollowTheHostNodeWouldReport() {
        // The web names these after `hostname`, so a host with letters outside ASCII is its punycode.
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://b\u{FC}cher.example/"]), "xn--bcher-kva.example")
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://%41.com"]), "a.com")
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://0x7f.1"]), "127.0.0.1")
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://www.github.com/login", "username": "jane"]), "github.com")
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://[::1]:3000/"]), "1")
        XCTAssertEqual(Items.suggestName(.login, ["url": "news.ycombinator.com"]), "news.ycombinator.com")
        // Without a scheme the web tries https:// in front, and an address that still fails falls back to the username.
        XCTAssertEqual(Items.suggestName(.login, ["url": "not a url at all", "username": "x y z"]), "x-y-z")
    }

    func testNothingThatReachesTheParserCanCrashIt() {
        // Lengths and shapes that overflow a naive port: very long numbers, a punycode label made to overflow, and
        // a long label of non-ASCII letters.
        let long = String(repeating: "9", count: 4000)
        XCTAssertNil(Items.webHost("https://a.com:\(long)"))
        XCTAssertNil(Items.webHost("https://\(long)"))
        XCTAssertNil(Items.webHost("https://xn--\(String(repeating: "z", count: 300)).com"))
        XCTAssertNotNil(Items.webHost("https://" + String(repeating: "\u{4F8B}", count: 300) + ".jp"))
        XCTAssertNil(Items.webHost("https://0x" + String(repeating: "f", count: 500)))
        XCTAssertNil(Items.webHost("https://[" + String(repeating: "1:", count: 500) + "]"))
    }
}
