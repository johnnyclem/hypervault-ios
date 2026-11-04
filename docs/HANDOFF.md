# The HyperVault iOS handoff: what was built, what was decided, what is open

The web team's handoff (`docs/mobile/handoff.md` in the hypervault repo) maps the web's design system and the Vault feature
onto iOS. This file says how the app follows it. The handoff marks a lot as **Proposal**: suggestions for the owner. This work
treated the handoff's own recommendations as the owner's decisions wherever it left a choice, and listed each one here so
any can be reversed.

## Decisions taken (the handoff's recommendations, adopted)

1. **Dark-native, light-ready.** The dark look is the web's stock tokens. The light look is the mirror in the iOS
   guides (the same roles, the proposed values). Each colour set has a light slot, a dark slot, and an Any slot that
   repeats the dark value (`scripts/gen_tokens.py`; `UIColor(named:)` is nil without Any). The app
   follows the system until the person's theme is worn: a worn theme pins the window to its own light or dark
   (`overrideUserInterfaceStyle` and `preferredColorScheme`, `HVAppStyle`), and there is no appearance picker of the
   app's own. A UI-test launch pins dark so the layout sweep still measures a dark page.
2. **Themes.** Stock unless the person picked one. The Appearance pane edits the account's theme (`profiles.theme`,
   `PATCH /api/dashboard-theme`); the server sends the accessible look for it (`GET /api/dashboard-theme` -> `{ theme, kit }`)
   and the app wears it (`StyleKitStore`, `StyleRuntime`), unless the phone's "Use this theme in the app" is off. Widgets and
   the Share sheet are stock (v1.1), and so is the system's launch frame and the first frame of the app's own launch view (the
   kept theme is read once the app runs: a light theme on a dark phone flashes the stock page at launch; worth a line in the
   release notes). The wording is new copy for the owner.
3. **iOS 26 minimum** (set in the Xcode project by the owner; `project.yml` follows). Liquid Glass is the system's on tab
   bars, sheets and toolbars, with `.glassEffect` for custom chrome and a solid `card` under Reduce Transparency.
4. **Four tabs:** Home, Projects, Memory, Mail (the tab overhaul; it replaced Home, Chat, Memory, You). Home is the chats
   (under a Chats / Group chats switch); with none at all, and only once the server has said so, it is a starter page (Start a
   chat, Keep something, a prompt to copy, the first-run card that asks for an agent's key). The old no-chats state's "Import
   your history" button is gone on purpose (Import is under Home's More and in Settings), and the key card shows only on the
   starter page, not above a list of chats (open for the owner: someone who chats first does not see the ask again on Home). The canvas is no tab: it is a
   screen pushed on Home (`Route.keep`) from the Keep button in Home's bar, and its page lives in `AppEnvironment.canvas`, so a
   paste that is waiting survives Back. Yours is the canvas's panel (also under Home's More; the Library is under the panel's
   More). Models left Home's bar: it is under More, which opens Settings > Models. Projects is the task boards, and a row opens the project's overview (the board in brief, who is working on it, the pages, memories and chats that go with it), which opens the full board; Mail carries its unread number. The avatar, on the first
   screen of every tab, opens an Account sheet with what the tab bar does not carry (Settings, Library, Group chats, Tools,
   Dreams, Truth, Admin for admins, Sign out). The pinned Menu list with drag-reorder (the web drawer's) is **not built**.
   Copy that sends a person somewhere says Home, More or Models, since there is no Chat tab; "Chat" stays where it names a
   conversation (Continue in Chat) and in the words that mirror the web (the Models pane's description, the import summary).
5. **Settings is a frame inside the Account sheet**, the first row of its menu, with seven panes in the web's order: General,
   Vault (the default for a link that names none), Agent keys, Models, Domain, Appearance, Import. It is one navigation stack
   (`AppRouter.accountPath`: the menu, the list of panes, a pane, what the pane pushes) on a phone and on an iPad, where the
   sheet is page-sized; the earlier iPad split view and its `youIsStack` are gone, so resizing an iPad window has no layout
   to swap and nothing to tear down. General also holds the phone-only settings under "On this phone".
6. **No "Agent connected"** (or "N agents connected", "Verified", "Connected") for an agent key: no route reports the
   server's check, and the app's own re-derivation of it was removed (handoff 5.10, 10). The Agent keys pane says only
   "One key per agent. A key is shown once, and comes with a setup challenge the agent completes to prove the link works."
   The server's `connect.md` line that says the row "reads Agent connected" is filtered out of the in-app steps.
7. **No native pairing approval.** The server checks a same-origin `Origin` header to prove a person at a page approved it,
   and the app never sets `Origin` (the Kit refuses any endpoint header of that name). `hypervault://pair` opens the
   website's `/pair` page in the in-app Safari sheet instead.
8. **Allow switches move only after the server agrees.** A tap shows a spinner in place of the switch; a 404 on a revoke
   means "already off" and never shows "No such grant."; "No such secret." closes the sheet and refreshes the list; a failed
   keys load shows the error and Try again with **no** switches (stricter than the handoff's "disabled switches", since a
   disabled off switch still claims "off").
9. **Rename and rotate stay** (`PATCH /api/secrets/<name>`) with the shipped RENAME strings. `.` and `..` are refused on
   create in the app (stricter than the server).
10. **Vault limits** (100 entries, 64 KB UTF-8 per value) are hard-coded in the Kit until capabilities carries them. The
    server cuts a description at 500 UTF-16 units without an error, and the add flow sends no description.
11. **No Upgrade button or price** is added in the app (App Review 3.1.1). The existing web sheet from the Domain screen is
    unchanged.
12. **Secrets on the phone:** a value is write-only (never read back); the one-time agent key is copied with `.localOnly`
    and a 60 second expiry; typed values are covered in the app switcher even with the Face ID lock off; vault entry names
    on disk use file protection; the session lives in the Keychain as "after first unlock, this device only" and a reinstall
    does not resurrect it.
13. **Words.** Labels are the web's, verbatim, from `lib/copy.ts` and the vault components; the first-run story uses the
    readers list ("Claude Code, Codex, Cursor, Gemini CLI, Grok Build or your own script") and never a chat app.

## Where the app goes beyond or against the handoff

- The Kit's website check follows WHATWG `new URL` as Node 22 runs it, tested against a table generated from Node and 600,000
  random addresses, but it is not a full UTS 46 port (compatibility mappings, bidi and unassigned code points): where it
  differs it accepts what the server refuses, and the server's 400 is shown.
- The Vault description is the web's line, verbatim, above the filters; at the largest accessibility size it fills the first
  screen.
- The vault entry opens as a sheet with `.medium`/`.large` detents (handoff 4.4) rather than a pushed screen.
- Going Back from a half-typed add form asks first (the web drops typed values silently); the system back button is hidden
  while the draft is dirty so the swipe cannot drop it either. Close is disabled while a save is in flight.
- The Import pane's file row no longer says "PDFs (up to 10 MB)": the server holds 50 MB on Pro and 1 MB on Free (the web's own
  line still says 10 MB; the owner may want to reconcile it).
- A link that names a tab but no screen (`hypervault://rooms`, `tab/home`) starts that tab from its first screen and closes any
  sheet over the tabs. The links that ask for the canvas (the Keep widget's `hypervault://keep`, `canvas`, `keep?text=`, and
  `yours`, `tab/yours`) start Home from its first screen and push the canvas on it in the same step, with the text or the
  Yours panel waiting for it. Installed widgets' `hypervault://tab/yours` and `tab/canvas` links keep working (`AppTab.home`
  keeps the raw value `canvas`); `tab/canvas`, which used to be the canvas, is now Home's chats, and `keep` is the link for the
  field. A link to Settings (`vault/account?tab=keys`, `settings`, `tab/you`) or to
  pairing presents the Account sheet over whatever shows and names no tab; the Agent keys pane presents the pairing page. The
  links of the tabs that went keep opening something: `tab/chat` and `/chat` open Home, `tab/taskboards`, `taskboards` and
  `projects` open Projects, `mail` opens Mail. `projects/<id>` (and `project/<id>`, or the board's `tasks-<id>` slug) opens
  that project's overview, pushed on Projects (`Route.project`); with no plain id it is the tab.
- Type names in the Kit and app still say `VaultItem...` (handoff 4.4 asks for "entry"): the ids and routes that carried the
  words are gone, so the names no longer leak, and a rename of the Kit's public API was not worth its risk without a compiler.
- The app icon is the supplied keyhole-hexagon artwork; the old dark and tinted variants were removed so iOS derives them.

## Needs the owner (not something the app can do)

| Item | What is needed |
| --- | --- |
| Account deletion (App Review 5.1.1(v)) | A self-serve route (today only `DELETE /api/admin/accounts/[id]` exists) and a decision on what it deletes |
| Sign in with Apple (4.8) | The Apple App ID and the Supabase Apple provider; production reports `apple: false`; the app already has the button |
| Privacy policy | A URL for App Store Connect and the app (the in-app link is relabelled "How HyperVault works" and opens the agent-facing `explain.md`) |
| Waitlist and App Review (2.1) | A demo account that is past the gate |
| Monetisation (3.1.1) | Whether Pro is sold in the app (IAP) or only on the web |
| Associated domains | The team and bundle ids and an AASA for hypervault.store; no `webcredentials:` (handoff 4.5) |
| "Agent connected" | A route that reports the server's setup-challenge check, so the app may show it |
| Admin status | A read-only way to learn whether the person is an admin (today a refused empty PATCH is the probe) |
| Pairing from the app | A bearer-specific path on the server that needs no `Origin` |
| Vault limits in capabilities | So the app need not hard-code them |
| Brand | The canonical mark and tagline for the App Store listing; dark and tinted icon variants |
| Copy for the owner | Appearance pane wording, the "Discard your changes?" dialog, "On this phone", Close/discard wording |

## The Xcode project

`HyperVault.xcodeproj` is tracked but is **not** regenerated by this work: `project.yml` is the source of truth and CI runs
`xcodegen generate` (`make project` does the same locally), so the tracked project is stale (it lacks the files added since
it was committed). Regenerating it would also drop settings that exist only in the tracked project, not in `project.yml`:
the development team, the device-only bundle id override and the 26.x deployment targets set by hand. If you want the
tracked project to be reproducible, move those into `project.yml` first.

## How it was checked

- The Kit (Foundation only) was built and tested on Linux and macOS in CI, and locally with a Swift 6.2 toolchain: 1049 tests
  run, 100 skipped (local-server E2E), 0 failures. Its JavaScript-parity tables were generated from Node 22.
- The Vault model, the grants state machine, the add-form draft and the router/deep-link logic were also compiled and run
  on Linux with small stubs of SwiftUI/UIKit (96 tests).
- The app and its extensions were built and tested on macOS CI, with 13 UI-test jobs that launch the app on a simulator against
  a canned server inside the app (journeys that read, journeys that write, layout sweeps in the dark and at the largest text
  size). CI has no compiler on this machine: every SwiftUI change was first compiled by CI.
- Every stream was reviewed adversarially by independent reviewers who tried to refute each finding with three skeptics each;
  35 confirmed findings (mostly low severity) were fixed. The reviews are the reason for the small, specific commits near the end.

## What could not be checked from here (device only)

The switch thumb, SecureField paste-then-edit, the Passwords bar and Save Password, VoiceOver announcement priority and focus
after a 409, Liquid Glass and the tab bar's unselected colour, the app-switcher cover's timing, Keychain migration, file
protection and the URL cache on a device, the Account sheet's page sizing on iPad, a non-empty `NavigationPath` applied to a
sheet's stack as it first presents, the Face ID prompt. They are in
`docs/DEVICE_TEST_PLAN.md`.
