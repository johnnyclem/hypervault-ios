#if DEBUG
import Foundation
import HyperVaultKit
import Observation
import SwiftUI

/// What the app wrote while a UI test drove it: every request that is not a read (a POST, a PATCH, a PUT, a DELETE), as
/// the canned server received it. A journey that creates, edits or deletes something asserts the result on the screen
/// AND that the app sent the write it should have, by reading this record through a hidden accessibility element
/// (`UITestWritesBeacon`, identifier `uitest.writes`).
///
/// A record holds the method, the path, the query, and for a JSON body the names of its fields with their values, except
/// that the value of a field that could be a secret is replaced by `<redacted>`. It is never the whole body, and nothing
/// in it can be used outside the canned server: the record exists only in a debug build launched by the UI tests.
final class UITestWriteLog: @unchecked Sendable {
    static let shared = UITestWriteLog()

    private let lock = NSLock()
    private var lines: [String] = []

    /// The longest a value is kept.
    private static let clip = 160

    /// Fields whose value is never kept, whatever it is.
    private static let secretFields: Set<String> = [
        "value", "secret", "password", "token", "key", "code", "number", "cvv", "pin", "api_key", "apikey",
        "access_token", "refresh_token", "authorization", "fields", "data",
    ]

    func record(_ request: URLRequest) {
        let line = Self.describe(request)
        lock.lock()
        lines.append(line)
        let all = lines.joined(separator: "\n")
        lock.unlock()
        Task { @MainActor in UITestWritesModel.shared.summary = all }
    }

    /// One line of JSON: `{"method":"PATCH","path":"/api/memories/m1","query":"branch=main","fields":{"title":"..."}}`.
    static func describe(_ request: URLRequest) -> String {
        var fields: [String: JSONValue] = [:]
        if let body = request.httpBody, !body.isEmpty {
            if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                for (name, value) in object {
                    fields[name] = describe(value, named: name)
                }
            } else if (try? JSONSerialization.jsonObject(with: body)) is [Any] {
                fields["_array"] = .string("[…]")
            } else {
                fields["_bytes"] = .string("\(body.count)")
            }
        }
        let entry: JSONValue = .object([
            "method": .string(request.httpMethod ?? "GET"),
            "path": .string(request.url?.path ?? ""),
            "query": .string(request.url?.query ?? ""),
            "fields": .object(fields),
        ])
        return entry.jsonString()
    }

    private static func describe(_ value: Any, named name: String) -> JSONValue {
        if secretFields.contains(name.lowercased()) { return .string("<redacted>") }
        return .string(render(value, depth: 0))
    }

    /// A value as one short text: a string, a number, true or false, null as is; a list as `[a|b]`; an object as
    /// `{name=value,name=value}`, one level down only (deeper, just the names), a secret's value as `<redacted>`.
    private static func render(_ value: Any, depth: Int) -> String {
        switch value {
        case let text as String:
            return text.count > clip ? String(text.prefix(clip)) + "\u{2026}" : text
        case let number as NSNumber:
            // A JSON true is an NSNumber that is a boolean; a 1 is not, and is not to be told as one.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is NSNull:
            return "null"
        case let list as [Any]:
            return "[" + list.map { render($0, depth: depth + 1) }.joined(separator: "|") + "]"
        case let object as [String: Any]:
            if depth >= 2 { return "{" + object.keys.sorted().joined(separator: ",") + "}" }
            let parts = object.keys.sorted().map { key -> String in
                let shown = secretFields.contains(key.lowercased()) ? "<redacted>" : render(object[key] ?? NSNull(), depth: depth + 1)
                return "\(key)=\(shown)"
            }
            return "{" + parts.joined(separator: ",") + "}"
        default:
            return "?"
        }
    }
}

/// A transport that notes every write on its way to the canned server.
struct UITestRecordingTransport: HTTPTransport {
    let inner: any HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let method = (request.httpMethod ?? "GET").uppercased()
        if method != "GET" && method != "HEAD" {
            UITestWriteLog.shared.record(request)
        }
        return try await inner.send(request)
    }
}

/// What the beacon shows: the lines of the log, one write each.
@MainActor
@Observable
final class UITestWritesModel {
    static let shared = UITestWritesModel()
    var summary = ""
}

/// A speck over the window with the log as its accessibility label, so a UI test can read what the app has sent
/// (`app.otherElements["uitest.writes"].label`). It draws almost nothing, takes no touches and exists only in a UI-test launch.
struct UITestWritesBeacon: View {
    var body: some View {
        if UITestHarness.isActive {
            Rectangle()
                .fill(Color.black.opacity(0.004))
                .frame(width: 3, height: 3)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(UITestWritesModel.shared.summary.isEmpty ? "no writes" : UITestWritesModel.shared.summary)
                .accessibilityIdentifier("uitest.writes")
        }
    }
}
#endif
