#if DEBUG
import HyperVaultKit
import SwiftUI

/// Everything a SwiftUI preview or a snapshot test needs to stand a screen up
/// without a network: an environment whose client answers from canned routes.
///
///     #Preview { PreviewHost(routes: [.json(.get, "/api/yours", yoursJSON)]) { YoursRootView() } }
extension AppEnvironment {
    @MainActor
    static func preview(
        routes: [MockRoute] = [],
        delay: TimeInterval = 0,
        user: AuthUser = AuthUser(id: "preview-user", email: "sam@example.com", displayName: "Sam Rivers"),
        capabilities: Capabilities = Capabilities()
    ) -> AppEnvironment {
        let transport = MockTransport(routes: routes, delay: delay)
        let server = ServerConfig(baseURL: URL(string: "https://preview.hypervault.test")!)
        let client = HVClient(baseURL: server.baseURL, transport: transport, tokens: StaticTokenProvider())
        let auth = AuthService(
            config: SupabaseConfig(url: URL(string: "https://preview.supabase.test")!, anonKey: "preview"),
            transport: transport,
            store: InMemorySecureStore()
        )
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-preview-\(UUID().uuidString)"))
        return AppEnvironment(client: client, auth: auth, capabilities: capabilities, user: user, server: server, cache: cache)
    }
}

extension AppModel {
    @MainActor
    static func preview() -> AppModel {
        AppModel(secureStore: InMemorySecureStore(), server: ServerConfig(baseURL: URL(string: "https://preview.hypervault.test")!))
    }
}

/// Wraps a screen in the environments the real app provides, inside a
/// navigation stack, ready for `#Preview` and snapshot tests.
struct PreviewHost<Content: View>: View {
    @State private var env: AppEnvironment
    @State private var model = AppModel.preview()
    private let content: Content
    private let embedInNavigation: Bool

    init(
        routes: [MockRoute] = [],
        capabilities: Capabilities = Capabilities(),
        delay: TimeInterval = 0.2,
        embedInNavigation: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        _env = State(initialValue: AppEnvironment.preview(routes: routes, delay: delay, capabilities: capabilities))
        self.content = content()
        self.embedInNavigation = embedInNavigation
    }

    var body: some View {
        Group {
            if embedInNavigation {
                NavigationStack { content }
            } else {
                content
            }
        }
        .environment(env)
        .environment(model)
        .tint(Palette.blue)
    }
}
#endif
