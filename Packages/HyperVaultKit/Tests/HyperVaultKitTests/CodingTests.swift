import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

final class CodingTests: XCTestCase {
    struct Row: Codable, Equatable {
        var sourcePrompt: String
        var artifactId: String
        var isJsx: Bool
        var createdAt: Date
    }

    func testSnakeCaseRoundTrip() throws {
        let json = #"{"source_prompt":"hi","artifact_id":"a1","is_jsx":true,"created_at":"2026-10-24T01:02:03.123456+00:00"}"#
        let row = try HVCoding.decoder().decode(Row.self, from: Data(json.utf8))
        XCTAssertEqual(row.sourcePrompt, "hi")
        XCTAssertEqual(row.artifactId, "a1")
        XCTAssertTrue(row.isJsx)

        let encoded = try HVCoding.encoder().encode(row)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("\"source_prompt\":\"hi\""))
        XCTAssertTrue(text.contains("\"artifact_id\":\"a1\""))
        let again = try HVCoding.decoder().decode(Row.self, from: encoded)
        XCTAssertEqual(again.sourcePrompt, row.sourcePrompt)
        XCTAssertEqual(again.createdAt.timeIntervalSince1970, row.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testVerbatimLeavesKeysAlone() throws {
        struct Headers: Codable { var map: [String: String] }
        let json = #"{"map":{"X-Api-Key":"k","first_name":"a"}}"#
        let value = try HVCoding.decoder(.verbatim).decode(Headers.self, from: Data(json.utf8))
        XCTAssertEqual(value.map["X-Api-Key"], "k")
        XCTAssertEqual(value.map["first_name"], "a")
    }

    func testDateFormsTheServerSends() {
        let postgres = HVDate.parse("2026-10-24T01:02:03.123456+00:00")
        let javascript = HVDate.parse("2026-10-24T01:02:03.123Z")
        let noFraction = HVDate.parse("2026-10-24T01:02:03Z")
        let noZone = HVDate.parse("2026-10-24T01:02:03")
        let offset = HVDate.parse("2026-10-23T21:02:03-04:00")
        XCTAssertNotNil(postgres)
        XCTAssertNotNil(javascript)
        XCTAssertNotNil(noFraction)
        XCTAssertNotNil(noZone)
        XCTAssertEqual(postgres?.timeIntervalSince1970 ?? 0, javascript?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        XCTAssertEqual(noFraction?.timeIntervalSince1970 ?? 0, noZone?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        XCTAssertEqual(noFraction?.timeIntervalSince1970 ?? 0, offset?.timeIntervalSince1970 ?? 1, accuracy: 0.001)
        XCTAssertNil(HVDate.parse("yesterday"))
    }

    func testEpochDates() throws {
        struct Stamp: Decodable { var at: Date }
        let seconds = try HVCoding.decoder().decode(Stamp.self, from: Data(#"{"at":1700000000}"#.utf8))
        let millis = try HVCoding.decoder().decode(Stamp.self, from: Data(#"{"at":1700000000000}"#.utf8))
        XCTAssertEqual(seconds.at, millis.at)
    }

    func testJSONValue() throws {
        let json = #"{"a":1,"b":[true,null,"x",2.5],"c":{"d":"e"}}"#
        let value = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["a"]?.int, 1)
        XCTAssertEqual(value["b"]?[0]?.bool, true)
        XCTAssertEqual(value["b"]?[1]?.isNull, true)
        XCTAssertEqual(value["b"]?[3]?.double, 2.5)
        XCTAssertEqual(value["c"]?["d"]?.string, "e")
        XCTAssertEqual(value.jsonString(), #"{"a":1,"b":[true,null,"x",2.5],"c":{"d":"e"}}"#)
    }

    func testMultipartEncoding() {
        var form = MultipartForm(boundary: "BOUND")
        form.addField("branch", "main")
        form.addFile("file", filename: "notes.md", mimeType: "text/markdown", data: Data("# Hi".utf8))
        let text = String(decoding: form.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("--BOUND\r\nContent-Disposition: form-data; name=\"branch\"\r\n\r\nmain\r\n"))
        XCTAssertTrue(text.contains("filename=\"notes.md\"\r\nContent-Type: text/markdown\r\n\r\n# Hi\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUND")
    }
}

final class CryptoTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(SHA256.hex(Data(long.utf8)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPKCEChallengeMatchesRFC7636() {
        // The worked example in RFC 7636 appendix B.
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierShape() {
        let verifier = PKCE.makeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(verifier, PKCE.makeVerifier())
    }

    func testBase64URLRoundTrip() {
        let data = Data([0xfb, 0xff, 0xfe, 0x01, 0x02])
        let text = data.base64URLEncoded
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(Data(base64URLEncoded: text), data)
    }

    func testAppleNonceHashesTheRawValue() {
        let nonce = AuthNonce.make()
        XCTAssertEqual(SHA256.hex(Data(nonce.raw.utf8)), nonce.hashed)
    }
}
