import Foundation

// Pairing: an agent with no key asks for one, shows its person a code, and the
// person approves it. The agent's side (POST /api/pair/start and /poll) is not
// the app's. The person's side is POST /api/pair/approve and /deny, which the
// server answers only when it was started with HYPERVAULT_PAIRING=1 (off, every
// pairing route is a plain 404). The web's source is app/api/pair/**,
// lib/pairing/{approver,codes,config}.ts and components/pair/pairing-prompt.tsx.
//
// The server shows the agent's label only on its own /pair page (rendered from
// the database); no route answers "what is this code for". So the app can show
// the code and the warning before the person answers, and the label the
// approval reports afterwards.

// MARK: Codes

public enum PairingCode {
    /// No vowels (no accidental words) and nothing that reads as another character (no 0/O, no 1/I/L).
    public static let alphabet = "BCDFGHJKMNPQRSTVWXZ23456789"
    public static let length = 8

    /// The stored form of a code a person typed or followed: upper case, with the spaces, hyphens
    /// and underscores people put in the middle taken out. Nil when what is left is not eight
    /// characters of the alphabet, so a malformed code never costs a lookup.
    public static func normalize(_ input: String) -> String? {
        guard input.count <= 32 else { return nil }
        let kept = input.uppercased().unicodeScalars.filter { scalar in
            !(scalar == " " || scalar == "-" || scalar == "_" || scalar.properties.isWhitespace)
        }
        let code = String(String.UnicodeScalarView(kept))
        guard code.unicodeScalars.count == length, code.unicodeScalars.allSatisfy({ alphabet.unicodeScalars.contains($0) }) else { return nil }
        return code
    }

    /// XXXX-XXXX, the way a code is shown and put in a link.
    public static func format(_ code: String) -> String {
        "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    /// Pulls a code out of what was pasted: a bare code, or the `verification_url` an agent printed.
    public static func extract(from text: String) -> String? {
        if let direct = normalize(text) { return format(direct) }
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = items.first(where: { $0.name == "code" || $0.name == "user_code" })?.value,
           let code = normalize(value)
        {
            return format(code)
        }
        // A code inside a sentence: XXXX-XXXX with the alphabet's characters.
        let pattern = "[\(alphabet)]{4}[ -][\(alphabet)]{4}"
        if let range = text.uppercased().range(of: pattern, options: .regularExpression),
           let code = normalize(String(text.uppercased()[range]))
        {
            return format(code)
        }
        return nil
    }
}

// MARK: Answers

/// `POST /api/pair/approve` answers `{ approved: true, label }`. The key never comes back here: it goes to the agent.
public struct PairApproval: Sendable, Decodable, Equatable {
    public let approved: Bool
    /// What the agent called itself (plain text, at most 60 characters).
    public let label: String?
}

/// `POST /api/pair/deny` answers `{ denied: true }`.
public struct PairDenial: Sendable, Decodable, Equatable {
    public let denied: Bool
}

/// What the pairing routes answer to a poll with no body: 400 when pairing is on, 404 when it is off.
public struct PairProbe: Sendable, Decodable, Equatable {}

/// The words the web's /pair page uses (lib/copy.ts, PAIR_*), verbatim.
public enum PairingCopy {
    public static let pageTitle = "Connect an AI tool"
    public static func askLine(_ label: String) -> String { "\(label) wants to connect to your HyperVault." }
    public static let anAgentAsks = "An AI tool wants to connect to your HyperVault."
    public static let warning = "Only approve if you just started this from your AI tool."
    public static let approveNote = "Approving gives it a key of its own. You can revoke the key any time under Account & keys."
    public static let codeHeading = "Code"
    public static let codeMatchLine = "Check that it matches the code your AI tool is showing."
    public static let approveLabel = "Approve"
    public static let denyLabel = "Deny"
    public static let workingLabel = "Working..."
    public static let approvedLine = "Approved. Go back to your AI tool; it will finish on its own."
    public static let deniedLine = "Denied. Nothing was shared."
    public static let enterLine = "Enter the code your AI tool is showing."
    public static let codeFieldLabel = "Code"
    public static let continueLabel = "Continue"
    public static let badCodeLine = "That is not a code. It is 8 letters and numbers, like BCDF-2346."
    public static let notFoundLine = "That code is not waiting for approval. Codes last 10 minutes; ask your AI tool for a new one."
    public static let failedLine = "That did not go through. Try again."
    public static let offlineLine = "Network hiccup. Nothing was changed. Try again."
    /// When the server has pairing turned off (every pairing route is a 404 there).
    public static let unavailableLine = "Pairing is not available on this server. Make a key in Account & keys and give it to your AI tool instead."
    public static let whereItGoes = "The key goes straight to your AI tool. You will not see it here."
}

/// The reasons an answer can fail that the screen treats differently.
public enum PairingFailure: Sendable, Equatable {
    /// The server has pairing off. Its pairing routes are a bare 404 `Not found.`
    case unavailable
    /// The code is wrong, ran out, was answered or was tried too often: the server's own sentence says which.
    case refused(String)

    /// A 404 that says exactly `Not found.` is the route not existing; a 404 with a sentence ("That code is
    /// not waiting for approval...") is a code nobody is waiting on.
    public static func classify(_ error: Error) -> PairingFailure {
        guard let hv = error as? HVError else { return .refused(PairingCopy.failedLine) }
        if case .api(let failure) = hv, failure.status == 404, failure.message == "Not found." { return .unavailable }
        if case .transport = hv { return .refused(PairingCopy.offlineLine) }
        return .refused(hv.userMessage)
    }
}

// MARK: Endpoints

extension PairingCode {
    /// The `Origin` the approve and deny routes require: the origin of the server being talked to
    /// (`https://host[:port]`). A native client has no page, so it says so itself; the server compares
    /// it with the `Host` it was reached on (lib/pairing/approver.ts, isSameOriginPost).
    public static func origin(of baseURL: URL) -> String {
        var origin = "\(baseURL.scheme ?? "https")://\(baseURL.host ?? "")"
        if let port = baseURL.port { origin += ":\(port)" }
        return origin
    }
}

extension Endpoint where Response == PairApproval {
    /// Lets the agent behind `userCode` have a key. Only a signed-in person's token works; an API key is refused.
    public static func pairApprove(userCode: String, origin: String) -> Endpoint<PairApproval> {
        Endpoint(.post, "/api/pair/approve", body: .jsonValue(["user_code": .string(userCode)]), headers: ["Origin": origin])
    }
}

extension Endpoint where Response == PairDenial {
    public static func pairDeny(userCode: String, origin: String) -> Endpoint<PairDenial> {
        Endpoint(.post, "/api/pair/deny", body: .jsonValue(["user_code": .string(userCode)]), headers: ["Origin": origin])
    }
}

extension Endpoint where Response == PairProbe {
    /// A poll with no `device_code`: refused with a 400 before it spends anything when pairing is on,
    /// a 404 when it is off. Tells the app whether to offer pairing at all. Needs no credentials.
    public static var pairProbe: Endpoint<PairProbe> {
        Endpoint(.post, "/api/pair/poll", body: .jsonValue([:]), auth: .none)
    }
}

public enum PairingAvailability {
    /// Whether the server has pairing turned on. Nil when the question could not be asked (offline).
    public static func probe(client: HVClient) async -> Bool? {
        do {
            _ = try await client.send(.pairProbe)
            return true
        } catch let error as HVError {
            if case .api(let failure) = error {
                if failure.status == 404 { return false }
                return true  // 400: it reached the handler, and the handler wanted a device_code
            }
            return nil
        } catch {
            return nil
        }
    }
}
