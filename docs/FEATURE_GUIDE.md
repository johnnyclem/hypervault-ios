# Building a feature

How a screen gets from "the web app can do this" to "the app does this", in the
shape every feature here already has. Read it once; the rules are few.

## The layers

```
Packages/HyperVaultKit   Foundation only. Models, endpoints, auth, cache, logic.
                         Tested on Linux and macOS with `swift test`.
Shared/                  Compiled into the app AND its extensions: design
                         system, Keychain, shared config. Extension-safe code only.
App/Core                 App-wide state: AppModel, AppEnvironment, router, toasts.
App/Features/<Name>      One folder per feature. A feature owns its folder.
ShareExtension, WidgetExtension, Tests/AppTests
```

The Kit has no UI and no Apple-only imports, which is why its tests run in
seconds on Linux CI. Anything with logic (parsing, merging, validating, a state
machine) belongs there with a test. Views stay thin.

## The web app is the spec

`/hypervault` (the web repo) is the source of truth, down to the words:

- the route handler under `app/api/<route>/route.ts` says exactly what the wire
  looks like (request fields, response shape, status codes, who may call it);
- `components/` and `app/` show the flows and states people see today;
- `lib/copy.ts` holds the product's sentences. Use them verbatim where a screen
  says the same thing. On first-run surfaces never use the words in
  `FIRST_RUN_BANNED` (MCP, tombstone, GraphRAG, grant, subdomain, AgentVault,
  wiki, vault item); power-user screens may.

`docs/mobile/` in that repo is an older plan. Where it disagrees with the code,
the code wins. Do not invent endpoints.

## Kit: models and endpoints

Models live in `Sources/HyperVaultKit/Models/<Domain>.swift`, endpoints in
`Endpoints/<Domain>Endpoints.swift` (the suffix matters: SwiftPM puts every file of a target in one namespace of object names, so `Models/Mail.swift` and `Endpoints/Mail.swift` collide), tests in `Tests/HyperVaultKitTests/<Domain>Tests.swift`.

```swift
public struct Widget: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let sourcePrompt: String?     // source_prompt
    public let createdAt: Date?          // created_at, any timestamp the server sends
}

extension Endpoint where Response == Widget {
    public static func widget(id: String) -> Endpoint<Widget> {
        Endpoint(.get, "/api/widgets/\(id)")
    }
}
// use:  let widget = try await client.send(.widget(id: "x"))
```

- Keys: snake_case on the wire becomes camelCase in Swift automatically, and
  `_id` / `_url` become `Id` / `Url` (`artifact_id` is `artifactId`).
- Be lenient. Servers add fields and omit them. Optional where the server may
  omit; a custom `init(from:)` with `decodeIfPresent` and a default for anything
  that would otherwise make a whole list fail to decode. Unknown enum cases map
  to a sensible default rather than throwing.
- If a response holds dictionaries whose keys must survive (tool input schemas,
  headers, labels) or mixes casings, pass `keys: .verbatim` and write explicit
  `CodingKeys`. `JSONValue` holds open-ended JSON.
- Request bodies: `.json(SomeEncodable)` (snake_cased) or `.jsonValue([...])`
  (verbatim). Multipart: `.multipart(MultipartForm)`. Plain text: `Endpoint(text:)`.
- Mutations are not retried (`idempotent` defaults to false). Mark a POST
  `idempotent: true` only when repeating it is harmless.
- **Name types with their domain** (`MindCommit`, `ChatMessage`, `MailMessage`,
  `TruthEntry`), because every feature shares one module. Grep before you add a
  public name.
- Tests decode fixtures copied from the route's real output, name the source
  file in a comment, and cover the error cases the route documents. Use
  `MockTransport` and `HVClient(baseURL:transport:tokens: StaticTokenProvider())`.

## App: a screen

A screen is a view plus an `@Observable` model. The model is created by its view
with the client it needs; it never reaches for globals.

```swift
@MainActor @Observable
final class WidgetsModel {
    enum Phase { case loading, loaded([Widget]), failed(String) }
    private(set) var phase: Phase = .loading
    private let client: HVClient
    init(client: HVClient) { self.client = client }

    func load() async {
        do { phase = .loaded(try await client.send(.widgets())) }
        catch { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
    }
}

struct WidgetsView: View {
    @Environment(AppModel.self) private var app      // toasts, router
    @State private var model: WidgetsModel
    init(client: HVClient) { _model = State(initialValue: WidgetsModel(client: client)) }
    ...
    .task { await model.load() }
}
```

- The init of a model is cheap and has no side effects (the parent may build
  throwaway copies); loading happens in `.task` or `.refreshable`.
- Entry points get `env` from `@Environment(AppEnvironment.self)` and pass
  `env.client` (and `env.cache`) down. See `App/Features/Root/YouRootView.swift`.
- Lists use `env.load(key) { try await client.send(...) }` for cached-then-fresh
  loading, and show `HVStaleBanner` when the first answer was the saved copy.
- Every screen that fetches has all four states: loading (`HVListSkeleton` or
  `HVLoadingState`), empty (`HVEmptyState`), error (`HVErrorState` with the
  server's sentence), and content. Pull to refresh on lists.
- Errors from actions go to `app.toasts.show(error: error)`; the server's own
  sentence is shown verbatim. Success is a light haptic (`Haptics.success()`)
  and, when the result is not obvious, a toast.
- Destructive actions ask first with `.confirmationDialog` (never `.alert` for
  choices). Optimistic updates roll back on failure.
- Navigation: push local screens with `NavigationLink(value:)` and
  `.navigationDestination(for:)` on local `Hashable` types. To reach another
  feature use the router: `app.router.open(.route(.memory(id: id)))`. The set
  of cross-feature routes is `Route` in `App/Core/DeepLink.swift`.
- Secrets are never shown after creation and are never logged. A value shown
  once is copied with `UIPasteboard.general.setItems([[...]], options: [.localOnly: true, .expirationDate: ...])`.

## Look and feel

Use the design system in `Shared/DesignSystem`; do not hard-code colours or
fonts. `Palette` (colour), `Font.hv*` (type, all Dynamic Type), `HV.Space` /
`HV.Radius` (the 4-point grid), `HVCard`-style `.hvCard()`, `HVRow`, `HVChip`,
`HVTag`, `HVIconBadge`, `HVSectionHeader`, the button styles (`.hvPrimary`,
`.hvSecondary`, `.hvGhost`), `.hvFieldChrome()` for inputs, `.hvGlass()` only for
floating chrome (composer, bars), never for lists. Lists are plain paper.

- Everything works in light and dark, at the largest Dynamic Type size, with
  VoiceOver (labels on icon-only buttons; combine row elements), with reduce
  motion, and with 44-point touch targets.
- Calm over clever. One filled action per screen. Motion that explains
  (a card arriving, a row leaving) is welcome; motion that decorates is not.
- iPad: content stays in a readable column (`.hvReadableWidth()`); lists may
  use the full width.

## Writing SwiftUI without a compiler at hand

The macOS CI job is the compiler. Keep it happy on the first push:

- Swift 5 language mode, iOS 17 minimum. Newer APIs go behind
  `if #available(iOS 26, *)` and `#if canImport(...)`.
- Small views. A `body` over about 40 lines becomes sub-views or computed
  properties; long `ViewBuilder` expressions are what type checkers time out on.
- Give closures and large literals explicit types when inference might guess.
- `@Observable` classes are `@MainActor`; no property observers (`didSet`) in
  them; no `ObservableObject` in new code.
- No third-party packages. No `print` (there is no logger yet; return errors).
- `swiftc -parse path/to/File.swift` checks syntax locally (the Linux toolchain
  cannot import SwiftUI, so it cannot type-check); real checking is CI.

## Previews and snapshots

Every screen ships a `#Preview` using `PreviewHost` (App/Core/PreviewSupport.swift),
which stands the screen up on canned routes:

```swift
#Preview { PreviewHost(routes: [.json(.get, "/api/widgets", #"{"widgets":[]}"#)]) { WidgetsScreen() } }
```

And one snapshot test per main screen in `Tests/AppTests/<Feature>SnapshotTests.swift`
(see `OnboardingSnapshotTests.swift`). CI renders them in light and dark and
publishes the PNGs to a `snapshots-<branch>` branch, which is how a screen is
looked at before anyone opens Xcode.

## Journeys: UI tests of the whole app

A snapshot draws one screen. A journey launches the real app on the simulator and walks its navigation with taps
and typing, which is what catches a crash on launch, a tab that does nothing, a sheet that never presents or a control
nothing can reach. They live in `Tests/UITests` (the `HyperVaultUITests` target, part of the `HyperVault` scheme).

**The UI-test mode.** A debug build launched with `-HV_UITEST -HV_UITEST_SCENARIO <name>` builds its `AppModel` on a
canned server instead of the real one (`App/Core/UITestHarness.swift`, one call in `HyperVaultApp`, compiled out of
release builds). The scenarios are `signedOut` (the welcome story and the way in), `signedIn` (a few things kept, memories,
chats, a connected model), `signedInEmpty` (the first run) and `waitlisted`. The network is a `MockTransport` over the routes in
`App/Core/UITestWorld.swift`, the secure store is in memory, the cache and the shared defaults are scratch, and the
canned hosts end in `.invalid`; anything that builds its own `URLSession` request is answered or refused by
`UITestURLProtocol`. A run never reaches a real server, the Keychain or anything a person left on the phone.

**Adding a journey.**

1. Give the control an identifier: `.accessibilityIdentifier("storey.thing")` (`canvas.send`, `yours.row.<id>`,
   `welcome.continue`). A plain-text button or a title is found by its real label instead, which also tests what
   VoiceOver reads. Put the identifier on the control itself (the button, the field, a row that combines its words),
   not on a container.
2. If the screen reads a route the scenarios do not answer, add it to `UITestWorld` in the shape the real route sends
   (`UITestWorldTests` decodes the canned answers through the Kit's own endpoints, so a route that drifts fails there
   in seconds), or reuse the screen's `*PreviewData.routes`.
3. Write the journey in `Tests/UITests`, subclassing `HyperVaultUITestCase`: `launch(.signedIn)`, then `step("...") { }`
   blocks that `tap`, `enter`, `require` an element or `waitUntil` something holds. Every wait is long because CI
   simulators are slow, every failure says what was missing, and each step keeps a screenshot with the result. Wait
   for the right element rather than sleeping, and fix a flaky journey at its cause (an identifier, a better wait),
   never by skipping it.

**Running them.** `make test-ui` (or `xcodebuild ... -scheme HyperVault -only-testing:HyperVaultUITests test`) on
any iPhone simulator; `make test-unit` runs the rest. CI quiets a clone of its simulator first
(`scripts/prepare_ui_simulator.sh`: no keyboard introduction, no autocorrect, Reduce Motion on), publishes the step
screenshots next to the snapshots (the `ui/` folder), and uploads the `.xcresult` when a journey fails.

## Definition of done

- Every behaviour the web has for the feature that makes sense on a phone is
  there; what is deliberately left out is listed in the feature's README note.
- Kit tests pass (`cd Packages/HyperVaultKit && swift test`), the app builds and
  its tests pass in CI, snapshots look right in light and dark.
- No hard-coded colours, no force-unwraps of server data, no secrets in logs,
  every list has its loading, empty and error states.
- A new tab, sheet or main control can be reached in a journey (an identifier, and a step if it is a new place).
