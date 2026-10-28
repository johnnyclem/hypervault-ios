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
- A line claims no more than a check that can fail has shown. The sentence "Only you
  can open it." on its own (`HVCopy.onlyYouLine`) goes only under a kept card whose
  response said the thing is private: not about a link, and not as a paraphrase on
  any screen. The web's landing line (`HVCopy.landingLine`), which carries the same
  words, is used verbatim on the first welcome page and on the sign-in screen and
  nowhere else before something is kept. The Face ID lock gates the screen and the device passcode
  opens it too, so nothing says "protected", "secure", "safe" or "encrypted on this
  phone" about it, and "locked" describes the lock screen and nothing else. A line
  about who can read a saved value names Claude Code, Codex, Cursor, Gemini CLI,
  Grok Build or your own script (`HVCopy.landingVaultAgents`), never a chat app: a
  chat app can connect but cannot read a value.

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
  choices). Optimistic updates roll back on failure, except for a switch that grants access: it moves only when the
  server agrees (`VaultAllowedKeysModel`, handoff 4.6), because a thumb that shows an allow nobody confirmed is a claim.
- Navigation: push local screens with `NavigationLink(value:)` and
  `.navigationDestination(for:)` on local `Hashable` types. To reach another
  feature use the router: `app.router.open(.route(.memory(id: id)))`. The set
  of cross-feature routes is `Route` in `App/Core/DeepLink.swift`.
- Secrets are never shown after creation and are never logged. A value shown
  once is copied with `UIPasteboard.general.setItems([[...]], options: [.localOnly: true, .expirationDate: ...])`.

## Secrets on the phone

- The session is in the Keychain as `AfterFirstUnlockThisDeviceOnly`, not synchronised
  (`Shared/KeychainSecureStore.swift`; the extensions read the same item). An item stored
  by an older build moves to that class when it is read. The Keychain outlives an uninstall,
  so the first launch of a new install ends whatever session it finds (`InstallMarker`,
  kept in the app's own preferences, which an uninstall removes). Tests that seed a session
  call `SharedState.begin()`, and the UI-test mode marks the install itself, or launch would
  end the seeded session as a leftover.
- A screen that shows or takes a value applies `.hvSensitive()` (or `.hvSensitive(model.key != nil)`
  for one that holds a value only sometimes). While one is up, the app switcher gets the blank
  card whether or not the Face ID lock is on; it never locks anyone.
- `DiskCache` files are written readable only after the first unlock, and nothing the server said
  to a signed-in person is kept in the system's URL cache (`HVURLCache`).
- Each bundle has its own `PrivacyInfo.xcprivacy` (app, share extension, widgets). A bundle that
  starts to use a required-reason API (user defaults, file timestamps, disk space, system boot
  time, active keyboards) declares its reason there; `PrivacyManifestTests` reads the sources and
  fails when a manifest and the code disagree.

## Look and feel

Use the design system in `Shared/DesignSystem`; do not hard-code colours or
fonts. `Palette` (colour), `Font.hv*` (type, all Dynamic Type), `HV.Space` /
`HV.Radius` (the 4-point grid), `HVCard`-style `.hvCard()`, `HVRow`, `HVChip`,
`HVTag`, `HVIconBadge`, `HVSectionHeader`, the button styles (`.hvPrimary`,
`.hvSecondary`, `.hvGhost`), `.hvFieldChrome()` for inputs, `.hvGlass()` only for
floating chrome (composer, bars), never for lists. Lists are plain paper.

- The look is the web's stock look, and it is dark only (handoff 2.2): Info.plist declares
  `UIUserInterfaceStyle = Dark`, `Palette` is one value per member, and no view branches on the colour scheme. There is
  no light palette, no Appearance setting and no accent picker; the one accent is the web's `primary` (the root
  `.tint(HVColor.primary)` and the `AccentColor` asset), and the selected tab takes `accent` through
  `UITabBarAppearance` (`HVTabBarStyle`), never a background, so the bar stays Liquid Glass. A light look later means
  filling each colour set's Any slot and dropping the Info.plist key.
- Colours are the web's tokens. `docs/brand/tokens.json` (a copy of the web repo's file) is turned into
  `Shared/DesignSystem/Colors.xcassets` (one single-appearance colour set per token, named for it, in a catalog under
  `Shared/` so the Share extension and the widgets get it too) and `HVTokens.generated.swift` by
  `scripts/gen_tokens.py` (`make tokens`). `HVColor` loads them by name (`HVColor.mutedForeground`), `Palette` is
  built from `HVColor`, and a colour that is not a token is a decision, not a convenience. Take a new copy of
  tokens.json when the web changes, run `make tokens`, and commit what it writes; CI's `tokens` job and
  `DesignTokensTests` fail when the file, the generated code and the compiled catalog disagree. The asset symbols
  and their SwiftUI extensions are off in `project.yml` because the sets share the web's names (`primary`, `background`,
  and `accent`, which also meets the global `AccentColor`).
- Contrast is checked, not assumed: `DesignContrastTests` holds the pairs the app draws text in to 4.5:1, and records
  the exceptions (white on `primary` is 3.68:1, so a label on the flat primary fill is bold; `primary` and
  `destructive` as text on raised paper fall under 4.5, so tinted text there uses `accent`; `primary` text on its own 12
  to 14% tint is 4.08:1 on paper, so small text on a `primary` tint, such as the step numbers, is `accent` too).
- Shapes, type and borders are the web's (handoff 2.4 and 2.5). Corner radii are named for their role in `HV.Radius`
  (`control` 8 for buttons and inputs, `card` 16, `surface` 20, `brandTile` 5), always `.continuous`. Type is the system
  face; no `design: .rounded` anywhere, and monospace only for what is typed or matched (`hvMono`) and for code
  (`HVCodePanel`). Section headings (`HVSectionHeader`) are sentence case. Borders are the border token at reduced
  strength: `Palette.border` (60%) on surfaces, `Palette.controlBorder` (70%) on controls, `Palette.divider` (50%)
  between rows.
- Buttons: `.hvPrimary` is flat `primary` with a bold label (white on it is 3.68:1, which only bold text passes),
  `.hvSecondary` is `muted` with a control border, `.hvDestructive` is `destructive`, none of them with a glow, and none
  with a spring (pressed is a dimmer fill). `hvFieldChrome` is the web's input: the page's own colour, 8pt, at least
  44pt high, a half-strength ring when focused and a `destructive` outline when `isInvalid` (with the reason in words).
  `HVTag` is the web's status chip (the colour as text, at 10% as the fill and at 40% as the border); `Palette.success`
  and `Palette.warning` are its emerald and amber.
- For the Vault and the settings panes: `HVTile` and `HVCardBrandTile` (tiles), `HVFilterPill` with `HVCount`,
  `HVCodePanel`, `HVEmptyBox`, and `HVSymbol` for the SF Symbol of each concept. `hvGlass` is `.glassEffect`, and solid
  `card` under Reduce Transparency.
- Symbols: `HVSymbol` names the SF Symbol of each concept (handoff 2.7), so the same idea draws the same glyph
  everywhere: a login is `globe`, a card `creditcard`, a key `key`, delete `trash`, copy `doc.on.doc` and copied
  `checkmark`, close `xmark`. A symbol beside words is decoration, so draw it with `HVIcon(name)` (or add
  `.hvDecorative()`), which VoiceOver skips; a `Label(title, systemImage:)` already hides its symbol. A symbol that is
  the whole label of a control is not decoration: the control gets an `accessibilityLabel`. One that carries a state the
  words do not (a failure triangle, a selected check without the `isSelected` trait) is left readable.
- Motion (handoff 2.6): never write a bare `withAnimation` or `.animation(_:value:)`. `.hvAnimation(_:value:)` and
  `HV.Motion.animate { }` are those two with Reduce Motion in front, `.hvBounce(value:)` is a symbol bounce that holds
  still under it, and `HV.Motion.entrance` is the web's entrance (ease-out, 0.2s). A looping or decorative animation
  reads `accessibilityReduceMotion` itself (Aurora, the thinking dots, the confetti). The icon button style swaps its
  spring for a dimmer fill, and the toast fades in place of sliding. A button says "Copied" for `HV.Motion.copiedHold`
  (1.5s), as the web's copy button does. System sheet and push animations are left to the system.
- Glass and bars: `hvGlass` is for floating chrome (a composer, an action bar, a legend), never a `.background(.bar)` or
  a material, and the system's navigation bar is not repainted (no `toolbarBackground`): on iOS 26 it carries its own
  scroll-edge effect.
- Sheets: every sheet has a visible way out (handoff 4.4 and 9). Most already have a `Cancel`, a `Done` or a `Close` in
  the navigation bar, or an `HVSheetHeader` with its xmark; a sheet that has none puts `.hvSheetClose(isDirty:)` on its
  root view inside the `NavigationStack`. It adds a "Close" button (xmark, `.cancellationAction`); while `isDirty` it
  also turns off the swipe and asks "Discard your changes?" first, because the web drops typed values on close without
  a word and the phone should not. Do not add it beside a Cancel, a Done or a Close that already does the job: two ways
  out read as a mistake, and a UI test that taps "Close" would find two buttons.
- Everything works at the largest Dynamic Type size, with
  VoiceOver (labels on icon-only buttons; combine row elements), with reduce
  motion, and with 44-point touch targets.
- Calm over clever. One filled action per screen. Motion that explains
  (a card arriving, a row leaving) is welcome; motion that decorates is not.
- iPad: content stays in a readable column (`.hvReadableWidth()`); lists may
  use the full width.

## Writing SwiftUI without a compiler at hand

The macOS CI job is the compiler. Keep it happy on the first push:

- Swift 5 language mode, iOS 26 minimum, so there are no availability checks for 26 or earlier. Anything newer goes
  behind `if #available` and `#if canImport(...)`.
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
(see `OnboardingSnapshotTests.swift`). CI renders them in the dark (the app's only look) and
publishes the PNGs to a `snapshots-<branch>` branch, which is how a screen is
looked at before anyone opens Xcode.

## Journeys: UI tests of the whole app

A snapshot draws one screen. A journey launches the real app on the simulator and walks its navigation with taps
and typing, which is what catches a crash on launch, a tab that does nothing, a sheet that never presents or a control
nothing can reach. They live in `Tests/UITests` (the `HyperVaultUITests` target, part of the `HyperVault` scheme).

**The UI-test mode.** A debug build launched with `-HV_UITEST -HV_UITEST_SCENARIO <name>` builds its `AppModel` on a
canned server instead of the real one (`App/Core/UITestHarness.swift`, one call in `HyperVaultApp`, compiled out of
release builds). The scenarios are `signedOut` (the welcome story and the way in), `signedIn` (a few things kept, memories,
chats, a connected model), `signedInEmpty` (the first run), `waitlisted` and `signedInAdmin` (`signedIn`, for a person the
server knows as an admin; for everyone else the admin check gets the 403 the real routes send). The network is a
`MockTransport` over the routes in `App/Core/UITestWorld.swift` and `UITestWorld+Screens.swift` (the keys, the address,
a room, Truth, the task boards, the import, sharing, admin: what changes while a journey plays, such as a key being made
or revoked, lives in a small object that one launch owns), the secure store is in memory, the cache and the shared defaults are scratch, and the
canned hosts end in `.invalid`; anything that builds its own `URLSession` request is answered or refused by
`UITestURLProtocol`. Animations are off, so the app settles at once after every tap. Release is never built in CI, so
`scripts/check_debug_only.py` (a step of the CI job) fails if any of this is not inside `#if DEBUG`. A run never reaches a real server, the Keychain or anything a person left on the phone.

**Getting to a screen.** The app has four tabs, Home, Chat, Memory and You, and the helpers of `HyperVaultUITestCase` follow
them: `openPane("keys")` opens a pane of the You tab by its id (`general`, `vault`, `keys`, `backends`, `domain`,
`appearance`, `import`; on a phone the tab opens on the vault, so the helper goes back to the list first, which is the case
that a pane chosen again from the list has to open), `openFromAccount("library", title: "Library")` opens a row of the
Account menu behind the avatar on Home (`account.<row>`), `openFromMemoryMenu("Digest", title: "Digest")` opens an item of
Memory's More menu, and `openYours()` opens the Yours panel.

**Adding a journey.**

1. Give the control an identifier: `.accessibilityIdentifier("storey.thing")` (`canvas.send`, `yours.row.<id>`,
   `welcome.continue`). A plain-text button or a title is found by its real label instead, which also tests what
   VoiceOver reads. Put the identifier on the control itself (the button, the field, a row that combines its words),
   not on a container.
2. If the screen reads a route the scenarios do not answer, add it to `UITestWorld` (or `UITestWorld+Screens.swift`) in the
   shape the real route sends, or reuse the screen's `*PreviewData.routes`. Routes are tried in order and the first
   match wins, and only the path is matched, so two reads of one path (`/rest/v1/artifacts`) are told apart in the route.
   An unmatched route is a 404, which a screen shows as an error: add the route rather than accept that screen.
   `UITestWorldTests` and `UITestScreensTests` decode the canned answers through the Kit's own endpoints, so a route
   that drifts fails there in seconds.
3. Write the journey in `Tests/UITests`, subclassing `HyperVaultUITestCase`: `launch(.signedIn)`, then `step("...") { }`
   blocks that `tap`, `enter`, `require` an element or `waitUntil` something holds. Every wait is long because CI
   simulators are slow, every failure says what was missing, and each step keeps a screenshot with the result. Wait
   for the right element rather than sleeping, and fix a flaky journey at its cause (an identifier, a better wait),
   never by skipping it.

**Journeys that write.** A journey that creates, edits or deletes something checks two things: what the screen shows
afterwards, and that the app sent the write it should have. The first needs a canned server that remembers:
`App/Core/UITestWorld+Writes.swift` has small stores (the pages, the memories, the vault entries, the boards, the mail)
that a route reads and changes, built fresh for every launch and answering in the shape of the real route (the unit
tests, `UITestWritesTests`, decode every answer through the Kit's own endpoints, as the others are). Its routes come
before the static ones, so where one answers a path it answers for the whole launch. The second is the record of writes
(`App/Core/UITestWrites.swift`): a recording transport notes every request that is not a read, as one line of JSON (method,
path, query, and each field of the body with its value, an object one level down as `{name=value}`; a field that could be a
secret, `value`, `password`, `token`, `number`, is `<redacted>`, so a typed password is in no record), and a hidden
accessibility element, `uitest.writes`, carries the lines. In a journey, `requireWrite("PATCH", "/api/memories/m6",
equal: ["title": "..."], contains: ["content": "..."])` waits until the app has sent it, and fails with everything the app did
send; `requireNoWrite` and `writeRecordText()` check that something was not sent. Read the record with no sheet over the
screen. A journey that closes the app and opens it again launches with `resuming: true` (`-HV_UITEST_RESUME`): the secure
store and the preferences are read back instead of starting like a first run, so it can check that a signed-out app does not
get its session back. When a flow is broken in the app (a screen that does not follow a rename, a list that does not
update after a write), fix the app, not the journey. A write journey that fails is a finding.

**The layout sweep.** `LayoutSweepTests` and `LayoutSweepScreensTests` launch the app dark and at the
largest accessibility text size, visit the tabs, what they open, the welcome story, the waitlist and every screen the You panes
and the Account menu open (and the one beyond it), and for each keep a screenshot and a text note (`LayoutReport`: controls under 44 points,
anything drawn off the screen) beside it. The app is dark whatever the phone is set to (Info.plist declares it), so the
dark sweep takes no launch argument. So that a sweep of the dark never looks at light screens, each dark screenshot is
first checked: the brightness of a strip down the left edge of the picture, which is the page's own background on every
screen, must be low; it is what proves the declaration reaches every screen.
The large text size is the system's own `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`. Beyond
that the sweep asserts only that the screen's key control can be tapped (a row is scrolled until its middle is clear of the
tab bar first). The point is to look: fetch `ui-snapshots-<branch>` after a run and read the screenshots. A new screen belongs
in the sweep when it has a layout of its own.

**Running them.** `make test-ui` (or `xcodebuild ... -scheme HyperVault -only-testing:HyperVaultUITests test`) on
any iPhone simulator; `make test-unit` runs the rest. CI runs thirteen UI jobs beside the unit tests, each building and
running on its own: `journeys` (everything not named below, so a new test class runs there until it is given a job),
`tabs-you` (`YouJourneyTests` and `TabsJourneyTests`), `screens-you` (`YouScreensJourneyTests`), `screens-more` (`AccountAndAdminJourneyTests` and `ContentJourneyTests`),
`writes-keep` (`MemoryAndVaultWritesJourneyTests` and `PagesWritesJourneyTests`), `writes-vault` (`VaultWritesJourneyTests`),
`writes-more`
(`BoardsAndMailWritesJourneyTests` and `SessionAndSettingsWritesJourneyTests`), `writes-think`
(`ThinkWritesJourneyTests`),
`sweep-dark` (the tabs, what they open, the welcome and the waitlist in the dark), `sweep-dark-screens` (the screens of the
You panes and the Account menu in the dark), `sweep-large` (the tabs, what they open, the welcome and the waitlist at the
large text size) and `sweep-large-keep` and `sweep-large-think` (the screens of the You panes and the Account menu at the large
text size, in two halves). A push waits for the slowest of them, which should stay at about 20 minutes. They have taken between 5 and 22
minutes each, depending on the machine GitHub gives the job (the same job has taken twice as long on a slow one); the
build and the simulator's start are about eight of those minutes, and the rest is the tests, of which the large text
sizes, which scroll, are the slowest. A job that goes over 30 minutes is stopped; if one regularly nears 20, split it by
test method the way the sweep is split. GitHub runs five macOS jobs at a time, so with the unit-test job the last ones start when
others have finished. A job after them publishes all the step screenshots and layout notes to the
`ui-snapshots-<branch>` branch (and each job uploads them as an artifact), and a job uploads its `.xcresult` when a test
fails.

XCUITest is slow where it looks: every query walks the screen, and `waitForExistence` always takes about a second.
`HyperVaultUITestCase.require` looks first and waits only when the element is missing; keep to it, and to few
queries per step, or a journey that takes seconds on a laptop takes minutes on CI.

## Definition of done

- Every behaviour the web has for the feature that makes sense on a phone is
  there; what is deliberately left out is listed in the feature's README note.
- Kit tests pass (`cd Packages/HyperVaultKit && swift test`), the app builds and
  its tests pass in CI, snapshots look right in the dark.
- No hard-coded colours, no force-unwraps of server data, no secrets in logs,
  every list has its loading, empty and error states.
- A new tab, sheet or main control can be reached in a journey (an identifier, and a step if it is a new place).
