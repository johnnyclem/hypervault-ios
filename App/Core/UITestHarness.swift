#if DEBUG
import Foundation
import HyperVaultKit
import UIKit

/// What the app opens into when the UI tests launch it.
enum UITestScenario: String, CaseIterable {
    /// The welcome story and the way in. The auth server offers Google and email.
    case signedOut
    /// The app, with a few things kept, memories, chats and a connected model.
    case signedIn
    /// The app with nothing kept and no model connected: the first run.
    case signedInEmpty
    /// The first run of someone who has no agent key either (`signedInEmpty` lists the preview keys), so the Home page
    /// asks them to connect one.
    case signedInNoKeys
    /// Signed in but not let in, until the invite code `UITestWorld.inviteCode` is redeemed.
    case waitlisted
    /// The same vault as `signedIn`, for a person the server knows as an admin (the You tab shows Admin).
    case signedInAdmin

    var hasSession: Bool { self != .signedOut }
}

/// The UI-test mode: a debug build that, when launched with
///
///     -HV_UITEST -HV_UITEST_SCENARIO <signedOut | signedIn | signedInEmpty | signedInNoKeys | waitlisted | signedInAdmin>
///
/// builds its `AppModel` on a canned server instead of the real one, so `HyperVaultUITests` can launch the whole app,
/// tap and type through it, and never touch the network, the Keychain or anything a person left on the phone.
///
/// - The network is a `MockTransport` over `UITestWorld`'s routes. The few reads that bypass the model's transport
///   (the page loader, the Supabase tables) go through `UITestURLProtocol`, which answers from the same routes and
///   refuses every other host.
/// - The secure store is in memory, seeded with a session for the scenarios that start signed in.
/// - The shared defaults are a scratch suite and the standard defaults are emptied, so each launch starts like a first one.
/// - The cache is a folder of its own in the temporary directory.
/// - Animations are off, so the app settles at once after every tap.
///
/// The whole thing is compiled only into debug builds, and `HyperVaultApp` reaches it through one call. A normal launch
/// never has the flag, so it never gets here.
enum UITestHarness {
    static let launchFlag = "-HV_UITEST"
    static let scenarioFlag = "-HV_UITEST_SCENARIO"
    /// A launch that carries on from the one before it: the secure store is read back from where the last launch left it
    /// instead of being seeded, so a journey can close the app and open it again to see whether it still has a session.
    static let resumeFlag = "-HV_UITEST_RESUME"

    /// The scenario this launch asked for; nil for a normal launch.
    static let requested: UITestScenario? = parse(CommandLine.arguments)

    static var isActive: Bool { requested != nil }

    /// The model for a UI-test launch, or nil when this is not one.
    @MainActor
    static func makeModel() -> AppModel? {
        guard let scenario = requested else { return nil }
        isolateState()
        // No animation: a journey waits for the app to go idle after every tap, and a push, a sheet or a spring that
        // takes half a second to settle is half a second of every step on a slow simulator.
        UIView.setAnimationsEnabled(false)

        // Every write the app makes is noted on its way to the canned server (UITestWrites.swift), for a journey to read.
        let transport = UITestRecordingTransport(inner: MockTransport(routes: UITestWorld.routes(for: scenario)))
        UITestURLProtocol.transport = transport
        _ = URLProtocol.registerClass(UITestURLProtocol.self)

        let resumes = CommandLine.arguments.contains(resumeFlag)
        var seed: [String: Data] = [:]
        if scenario.hasSession, !resumes, let data = try? HVCoding.encoder(.verbatim).encode(UITestWorld.session()) {
            // The key AuthService keeps its session under.
            seed["hypervault.session"] = data
        }
        if scenario == .signedIn || scenario == .signedInAdmin {
            // Gives the canvas's Paste button something to paste, without the system asking whether the app may read it:
            // the app wrote it itself.
            UIPasteboard.general.string = UITestWorld.pasteText
        }

        return AppModel(
            secureStore: UITestSecureStore(seed: seed, file: secureStoreFile, resumes: resumes),
            server: ServerConfig(baseURL: UITestWorld.appURL),
            transport: transport,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-uitest-\(UUID().uuidString)", isDirectory: true)
        )
    }

    /// Where the in-memory secure store keeps a copy, so that the next launch (with `-HV_UITEST_RESUME`) finds what this one
    /// left. It is in the app's temporary folder, holds only the canned session, and is removed by every launch that is not a resume.
    private static var secureStoreFile: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hv-uitest-secure-store.json")
    }

    private static func parse(_ arguments: [String]) -> UITestScenario? {
        guard arguments.contains(launchFlag) else { return nil }
        guard let at = arguments.firstIndex(of: scenarioFlag), arguments.indices.contains(at + 1) else {
            preconditionFailure("\(launchFlag) needs \(scenarioFlag) followed by one of \(UITestScenario.allCases.map(\.rawValue)).")
        }
        guard let scenario = UITestScenario(rawValue: arguments[at + 1]) else {
            preconditionFailure("Unknown UI-test scenario \"\(arguments[at + 1])\". Use one of \(UITestScenario.allCases.map(\.rawValue)).")
        }
        return scenario
    }

    /// A phone that has never run the app: no preferences, and shared defaults that belong to this launch alone. A launch
    /// that resumes the one before keeps what that one left (its preferences and the markers of who was signed in), as a
    /// phone does when the app is closed and opened again.
    @MainActor
    private static func isolateState() {
        let resumes = CommandLine.arguments.contains(resumeFlag)
        if !resumes, let bundle = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundle)
        }
        // Emptied preferences look like a new install, and a new install ends the session it finds. The seeded session is
        // this launch's own.
        InstallMarker().mark()
        let suite = "hv.uitest"
        let scratch = UserDefaults(suiteName: suite)
        if !resumes { scratch?.removePersistentDomain(forName: suite) }
        SharedConfig.scratchDefaults = scratch
    }
}

/// A secure store in memory that starts with whatever the scenario seeds, so the Keychain is never read or written. It also
/// keeps a copy in a file of the app's temporary folder, which a launch with `-HV_UITEST_RESUME` reads back (a launch
/// without it starts the file over): that is how a journey closes the app and opens it again to see what it remembers.
actor UITestSecureStore: SecureStore {
    private var values: [String: Data]
    private let file: URL?

    init(seed: [String: Data] = [:], file: URL? = nil, resumes: Bool = false) {
        self.file = file
        if resumes, let file, let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: Data].self, from: data) {
            values = stored
        } else {
            values = seed
        }
        if let file, let data = try? JSONEncoder().encode(values) {
            try? data.write(to: file, options: .atomic)
        }
    }

    func get(_ key: String) -> Data? { values[key] }
    func set(_ value: Data, for key: String) {
        values[key] = value
        persist()
    }
    func remove(_ key: String) {
        values[key] = nil
        persist()
    }

    private func persist() {
        guard let file, let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// Answers the requests that do not go through the model's transport (a few screens build their own client, and the page
/// loader uses `URLSession.shared`) from the same canned routes, and refuses every host that is not the canned server's.
/// Registered process-wide in `UITestHarness.makeModel`, so a UI test cannot reach a real server by any path that uses
/// `URLSession`. (A web view's own subresource requests do not pass here; the canned pages have none.)
final class UITestURLProtocol: URLProtocol {
    /// The same transport the model uses. Set before the protocol is registered.
    nonisolated(unsafe) static var transport: (any HTTPTransport)?

    private static let hosts: Set<String> = Set([UITestWorld.appURL, UITestWorld.supabaseURL].compactMap(\.host))

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let url = request.url
        let transport = Self.transport
        let answer: (HTTPResponse) -> Void = { [weak self] canned in
            guard let self, let url,
                  let http = HTTPURLResponse(url: url, statusCode: canned.status, httpVersion: "HTTP/1.1", headerFields: canned.headers)
            else { return }
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: canned.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        let fail: (Error) -> Void = { [weak self] error in
            guard let self else { return }
            self.client?.urlProtocol(self, didFailWithError: error)
        }
        guard let host = url?.host, Self.hosts.contains(host), let transport else {
            // Not the canned server: nothing leaves the phone.
            fail(URLError(.notConnectedToInternet))
            return
        }
        Task {
            do {
                answer(try await transport.send(request))
            } catch {
                fail(error)
            }
        }
    }

    override func stopLoading() {}
}
#endif
