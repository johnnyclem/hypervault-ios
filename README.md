# HyperVault for iOS

The native iPhone and iPad app for [HyperVault](https://hypervault.store): **keep what
your AI just made, and only you can open it.**

It is a SwiftUI client for the same account, the same data and the same API as the
web app. Nothing about the server is forked: the phone signs in with Supabase and
talks to `hypervault.store` with a bearer token.

## What it does

| | |
| --- | --- |
| **Canvas** | A quiet page and a field. Paste something to keep it, say "show my memories", "pull the trip notes onto the page", "hide that", or just ask. The canvas follows the web app's rules word for word (the command grammar is a tested port of `lib/canvas/commands.ts`). |
| **Yours** | Everything kept, most recently used first: memories, pages, files, groups of files and keys, with the four quiet filters and search. |
| **Memory** | The memory wiki (search with recall, ask, a force-directed graph), memorize from text, a file or a link, and "Git for a Mind": branches, commit log, compare, merge with conflict resolution, time travel, restore and undelete. Dreams and Digest review. |
| **Chat** | Conversations and group rooms with several agents, your own models (connected through the server, or on your own network and called by the phone directly), replies you can keep, rate and read aloud, and on-device chat where Apple Intelligence exists. |
| **You** | The Library (files as a file manager, with a list and graph view) and pages rendered in a sandboxed web view with sharing, source editing and history; saved logins, cards and keys; agent keys and the Connect picker for 33 clients; pairing; mail; the truth ledger and its swipeable review docket; task boards; tools (MCP servers); import of ChatGPT, Claude, Gemini and Grok histories; your address; admin. |

Only a phone can do these, so the app does them:

- **Keep from anywhere**: a share extension keeps text or a link from any app, and
  when there is no network it saves to an outbox the app flushes later.
- **Face ID lock** and a blank app-switcher card.
- **Spotlight**: kept pages and memories in system search (never keys).
- **Widgets**: Yours on the Home Screen and Lock Screen; a one-tap Keep widget.
- **Siri and Shortcuts**: "Keep this in HyperVault".
- **Dictation** (on device where supported) and **page scanning** into the canvas.
- **Haptics**, a first-keep celebration, sidebar tabs on iPad, light and dark.

## Run it

You need a current Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). CI builds with
the newest Xcode on GitHub's macOS runner (26.x when this was written); the deployment target is iOS 17.

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put your DEVELOPMENT_TEAM in it
make open                                                # generates HyperVault.xcodeproj and opens it
```

Run the `HyperVault` scheme on a simulator or a device. Sign in with Apple needs a
paid team; everything else works with a free one if you remove the capabilities you
cannot get (see `project.yml`).

`make help` lists the rest. `make test-kit` runs the Kit's tests (they run on Linux
too: `cd Packages/HyperVaultKit && swift test`), and `make test` runs the app's.

### Point it at the server

By default the app talks to `https://hypervault.store`. Settings > Advanced switches
to another deployment, and `HV_DEFAULT_SERVER` in `Config/Base.xcconfig` changes the
default. The app reads `GET /api/capabilities` at launch, which tells it the Supabase
project to sign in against, what the server supports and its limits.

### What the server needs

- **Bearer auth on the session-only routes.** Most routes already accept a Supabase
  bearer token. `/api/keys`, `/api/invite/redeem`, `/api/onboarding`,
  `/api/artifacts/[slug]/source`, `/api/pair/*`, `/api/admin/*` and the private
  `/a/[slug]` page used to read the web cookie only; that is fixed by
  [hypervault#180](https://github.com/johnnyclem/hypervault/pull/180), merged on 2026-10-26.
  A deployment older than that still refuses them: the app signs in, keeps, chats and
  browses, and those screens show the server's own sentence. Where a route is cookie-only
  and a read is possible another way, the app reads the same rows through Supabase with
  the person's own token (the keys list, claimed addresses, pins and pages shared with
  you), exactly as the web's account page does.
- **Sign-in redirects.** Add `hypervault://auth/callback` to the Supabase project's
  redirect allow-list. Sign in with Apple needs the Apple provider turned on in
  Supabase; email codes need the email provider. The sign-in screen offers only what
  the project allows (`GET /auth/v1/settings`).
- **Universal links** (optional): serve `/.well-known/apple-app-site-association`
  for `hypervault.store` so `https://hypervault.store/a/<slug>` opens in the app. The
  `hypervault://` scheme works without it.

## How it is built

```
Packages/HyperVaultKit   Foundation only. API client, auth, models, caches, logic.
                         Tested with `swift test` on Linux and macOS.
Shared/                  Design system, Keychain, shared config. Compiled into the app
                         and both extensions.
App/                     The app: Core (state, router, links), Features/<Name>.
ShareExtension/          Keep from the share sheet.
WidgetExtension/         Home Screen and Lock Screen widgets.
Tests/AppTests/          App tests and snapshot renders.
```

- **One client.** `HVClient` adds the bearer token, refreshes it once on a 401,
  retries safe requests on transient failures and keeps the server's own sentences.
  `AuthService` is Supabase Auth on device: PKCE for Google, the id-token exchange for
  Apple, emailed codes, silent refresh. The session lives in a Keychain group the
  extensions share.
- **Logic in the Kit, views thin.** Anything with rules (the canvas commands, card
  state, pull resolution, link parsing, the outbox policy, conflict resolution) is
  plain Swift with tests, ported from the web app and checked against its own test
  cases.
- **Read cache, never a second source of truth.** Lists load from a per-user disk
  cache first and refresh behind it; sign-out wipes it.
- **Adding a feature** is described in [docs/FEATURE_GUIDE.md](docs/FEATURE_GUIDE.md).

### CI and looking at screens

`.github/workflows/ios.yml` runs the Kit's tests on Linux and builds and tests the app
on a macOS simulator. The app's snapshot tests render screens in light and dark and the
workflow publishes the PNGs to a `snapshots-<branch>` branch, so a screen can be looked
at without opening Xcode. Ten more jobs run the UI tests beside them (the journeys; the
screens behind the You tab, and the content and account journeys, in two; the journeys that write, in three; the layout
sweep in the dark in one and at a large text size in three) and publish what the app looked like at each step to `ui-snapshots-<branch>`. Each job builds the
app for itself and has taken between 5 and 22 minutes, depending on the machine GitHub gives it (the build and the
simulator's start are about eight of them); GitHub runs five macOS jobs at a time, so the last ones start when the first
have finished.

### How it is tested

Four layers, each catching what the one below cannot see:

- **The Kit's unit tests** (`make test-kit`, Linux and macOS): the API client, auth, every model and rule.
- **The app's unit tests** (`make test-unit`): screen state machines, link parsing, the sign-in and access phases.
- **Snapshot renders**: every screen drawn in light and dark to PNGs, published by CI.
- **UI tests** (`make test-ui`, the `HyperVaultUITests` target): the whole app launched on a simulator and driven
  through its main journeys with taps and typing, so a crash on launch, a broken navigation stack, a sheet that never
  presents or a control nothing can reach fails CI.

The UI tests need no server. A debug build launched with `-HV_UITEST -HV_UITEST_SCENARIO <signedOut | signedIn |
signedInEmpty | waitlisted | signedInAdmin>` builds its model on a canned server inside the app
(`App/Core/UITestHarness.swift`, `UITestWorld.swift` and `UITestWorld+Screens.swift`, compiled out of release builds),
with an in-memory secure store and scratch defaults, so a run never touches the network, the Keychain or the phone's own
state. They cover:

- the **journeys**: the welcome story, sign-in and the email code sheet, the canvas (keep, ask, show, hide), the Yours,
  Memory and Chat tabs, the Library (list and graph), Settings, the first run and the waitlist;
- every **screen the You tab opens**, against canned answers that give it real content: Logins, cards & keys (and one
  entry), Mail (the inbox, then a thread), Truth (the ledger, an entry's ancestry, the review docket), Tools (and a
  server), Your address (and one), Import (a pasted conversation read and sent), Dreams, Digest, Task boards (a board,
  then a task), Account & keys (Connect your AI through to a key that is shown once and copied, and revoking a key) and,
  for an admin, Admin (minting an invite code, switching it off, Accounts & waitlist); and a memory in full, Memory's Ask
  mode, a conversation and a room that take a message and answer it, a page from the Library with its Share, History
  and Details sheets;
- the **journeys that write** (`Tests/UITests/*WritesJourneyTests.swift`): signing out (the welcome story, and a launch
  afterwards that does not bring the session back), Settings (appearance, accent and haptics stay after leaving the
  screen and after closing the app), a memory's title and text edited and a memory forgotten, a login added, renamed and a
  card deleted, a task board made with tasks added, ticked along and marked done, a note composed and a reply written in
  its thread, a page made from pasted text and its source edited, a page made public, its link shown, and deleted, the
  look and the home page of a claimed address, a dream's connections accepted and rejected, a split of a memory applied in
  Digest (Memory then has its parts), and a chat begun from its first message and deleted.
  The canned server keeps what they write (`App/Core/UITestWorld+Writes.swift`, a fresh store for every launch) and
  answers in the shape of the real routes. Each journey checks what the screen shows and also what the app sent: every
  request that is not a read is noted (method, path, the names and values of the body's fields, never a secret's value)
  and shown through a hidden accessibility element, `uitest.writes` (`App/Core/UITestWrites.swift`, debug builds only);
- a **layout sweep**: the main screens and every screen the You tab opens, launched in the dark appearance (the app's own
  Appearance preference as a launch argument, and each dark screenshot is checked to be dark before it is kept) and at the
  largest accessibility text size, a screenshot of each, and a note of every control under 44 points or drawn off the screen.

They do not cover: a real sign-in (Google, Apple, a real email code), a real server, a real model, mail provider or
payment (the app opens the web for those); anything that needs a device (Face ID and the biometric lock, dictation,
the document scanner, the camera, widgets, the share extension, Spotlight, notifications, on-device models); the
system's own sheets and pickers (the file importer, the share sheet, Safari); screens that are opened and read but not
edited (creating a room or a ledger, changing a room's agents, deciding a truth or adding to Truth, claiming an address);
renaming a chat, and deleting a task or a board (neither the app nor the server has a way to); landscape, iPad, and text sizes
other than the default and the largest accessibility one. The sweep does not visit the Memory graph, the Library's graph
and inbox views, the models screen or Admin. Layout is judged by looking at the sweep's screenshots: a test fails only when a screen's key control
cannot be reached, or when a screenshot of the dark sweep turns out to be light; nothing compares pictures. To run them locally:

```sh
make test-ui
# or, on a simulator you choose:
xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO -only-testing:HyperVaultUITests test
```

To add a journey, give the controls identifiers (`.accessibilityIdentifier("canvas.send")`), teach `UITestWorld` any
route the screen needs, and write steps in `Tests/UITests`; [docs/FEATURE_GUIDE.md](docs/FEATURE_GUIDE.md) has the
details. Each step keeps a screenshot with the result, and CI publishes them to the `ui-snapshots-<branch>` branch
(`git fetch origin ui-snapshots-<branch>`), in a job that runs beside the unit tests.

### Server gaps the app works around

Found while building against the real routes. None block the app, and each is a small
server change if you want the app to do more:

- **Admin has no list routes**, and the tables have no read policy for a user's token, so the
  Admin screen cannot list invites, the waitlist or accounts. It mints invites and acts on
  an account ID you paste, and remembers codes minted on the phone.
- **Pairing is switched off in production** (`/api/pair/*` answers 404), so the app hides
  that row and says so when it is off.
- **The MCP sign-in callback needs the web cookie**, so connecting a tool that signs in
  through the browser works only while you are also signed in to the site in Safari.
  Redirecting that callback to `hypervault://mcp-oauth?ok=1` (the app already understands
  it) would fix it.
- **Some lists are capped by the routes**: Yours at 50 rows, `/api/artifacts` at 200,
  memories at 200. The screens say so and lean on search.
- **No streaming for remote chat** (see below), and **imports are synchronous**, so the app
  sends them in batches and resumes.
- **Mind restore and merge preview are inferred.** `GET /api/mind/state` does not return each memory's
  `revision_id`, so a restore finds the revision by commit time and content; and `POST /api/mind/merge` has
  no dry run, so the preview says how the two branches differ rather than what the merge will do. The app
  already uses `revision_id` when the route sends it.

## Deliberate limits

- **Not streaming.** `POST /api/chat` answers after the whole turn, so remote chats
  show a "thinking" state. On-device chat streams.
- **Secrets stay on the server.** Saved logins, cards and keys are write-only by
  design: the app creates, names and controls who may use them, and never shows a
  stored value again.
- **Payment is on the web.** Upgrading opens the web page; there is no In-App Purchase.
- **The web's 37 style themes** are CSS looks for web pages and are not ported; the app
  has system light and dark and five accents.
- **Models on your own network** (Ollama, LM Studio) are called by the phone directly,
  because the server refuses private addresses. They stream, take no tools and need the
  local network permission.
- **Dreams and Digest** run when you ask, as the server does them; there is no background
  job to wait for.

## What has and has not been tested

- The Kit (API client, auth, every model and rule) has about 860 unit tests, run on Linux and
  macOS in CI. Fixtures follow the routes' real output.
- The app builds for the simulator in CI with 482 tests (screen state machines, link
  parsing, sign-in and access phases) and renders every screen in light and dark, and the
  main ones at the largest text sizes, to PNGs the workflow publishes.
- CI also launches the whole app and drives it: UI tests walk the welcome story, sign-in, the canvas (keep, ask,
  show, hide), Yours, Memory, Chat, the Library, Settings, every screen the You tab opens, the first run and the
  waitlist, and create, edit and delete through the screens (sign-out, memories, vault entries, boards, mail, pages),
  checking what the app sent, on a canned server inside the app, and sweep the main screens in the dark appearance and at the largest
  accessibility text size. They do not cover a real sign-in, a real server, or anything that needs a device
  (Face ID, dictation, the scanner, widgets, the share extension); "How it is tested" lists the rest.
- The Kit's models decode the response shapes a real deployment sent for about twenty authenticated endpoints
  (Yours, artifacts and groups, the connections graph, chat lists and settings, memories, Mind, dreams, digest,
  jobs): field names, types, nulls and nesting were captured from production on 2026-10-26 and are pinned in
  `ProductionShapeTests`, which counts every row because most models decode leniently.
- A live contract check (`HV_LIVE_SERVER=https://hypervault.store swift test --filter LiveServerTests`, read-only,
  no credentials) passes against production: the real `/api/capabilities` answer decodes and names a Supabase
  project, the project offers Google and email sign-in (Apple was off when checked), an anonymous call gets a
  readable 401, the pages the app links to exist, and the real GoTrue's refusals of a refresh token it never
  issued end the session the way the Kit expects.
  readable 401, and the pages the app links to exist.
- The signed-in routes have been run for real, on a Linux box, against the web app itself: `scripts/e2e` brings up
  PostgreSQL with the web repo's migrations, a Supabase stand-in (fake sign-in, a PostgREST-compatible layer with
  real row-level security) and the unmodified web app, and `LocalServerE2ETests` / `LocalE2E*Tests` drive the Kit's
  endpoints through every feature area with throwaway people (89 tests, skipped unless `HV_E2E_LOCAL_SERVER` and
  `HV_E2E_LOCAL_TOKEN` are set). It reaches 401, 403, 404, 409, 412, 413, 428 and 429 from real routes. It does
  not cover a real model or mail provider, pgvector, or Supabase itself. How to run it and what it leaves out:
  [docs/LOCAL_E2E.md](docs/LOCAL_E2E.md).
- **Not yet done:** a run on a physical device, against the production Supabase project, with
  a real Google or Apple sign-in. The local stand-ins for sign-in and for PostgREST are written from their
  documented behaviour, so the Kit's direct Supabase reads (the keys list, claimed addresses, pins, shared pages,
  invite redeem) are the calls most exposed to a difference from the real services. On-device chat (Foundation Models), Face ID, dictation,
  the scanner, widgets and the share extension compile and are exercised only as far as the
  simulator allows. Expect rough edges there, and please report them. [docs/DEVICE_TEST_PLAN.md](docs/DEVICE_TEST_PLAN.md)
  is the checklist for trying them on a phone.

## License

MIT, as the rest of HyperVault.
