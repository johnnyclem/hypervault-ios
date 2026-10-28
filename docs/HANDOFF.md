# The HyperVault iOS handoff: what was built, what was decided, what is open

The web team's handoff (`docs/mobile/handoff.md` in the hypervault repo) maps the web's design system and the Vault feature
onto iOS. This file says how the app follows it. The handoff marks a lot as **Proposal**: suggestions for the owner. This work
treated the handoff's own recommendations as the owner's decisions wherever it left a choice, and listed each one here so
any can be reversed.

## Decisions taken (the handoff's recommendations, adopted)

1. **Dark only.** The stock look is the web's, and the web has no light palette (handoff 2.2). `UIUserInterfaceStyle` is
   `Dark`; the 15 stock colours are single-appearance asset-catalog colour sets generated from `docs/brand/tokens.json`
   (`scripts/gen_tokens.py`, checked in CI). The System/Light/Dark and accent pickers are gone. To add a light look later:
   fill each colour set's Any slot, move the stock value to Dark, and drop the Info.plist key.
2. **Themes.** Stock only. The Appearance pane is the web dashboard's theme (`profiles.theme`, `PATCH /api/dashboard-theme`),
   labelled as such, and it never claims the app restyled. The wording is new copy for the owner.
3. **iOS 26 minimum** (set in the Xcode project by the owner; `project.yml` follows). Liquid Glass is the system's on tab
   bars, sheets and toolbars, with `.glassEffect` for custom chrome and a solid `card` under Reduce Transparency.
4. **Four tabs:** Home, Chat, Memory, You. Yours is the Home canvas panel (Library under More). The avatar opens an Account
   sheet with what the dock does not carry (Library, Mail, Task boards, Account & keys, Group chats, Tools, Import, Dreams,
   Truth, Admin for admins, Sign out). The pinned Menu list with drag-reorder (the web drawer's) is **not built**.
5. **You is a settings frame** with seven panes in the web's order: General, Vault (the default), Agent keys, Models,
   Domain, Appearance, Import. On an iPhone it is a stack (the list, then the pane); on an iPad it is a
   `NavigationSplitView` with the list beside the pane. The layout is chosen once by device idiom, not by window width, so
   resizing an iPad window never rebuilds the tab. General also holds the phone-only settings under "On this phone".
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
- A link that names a tab but no screen (the Keep widget, `hypervault://rooms`, `tab/yours`) starts that tab from its first
  screen and closes any sheet over the tabs; installed widgets' `hypervault://tab/yours` and `tab/canvas` links keep working.
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
protection and the URL cache on a device, `NavigationSplitView` in compact width and on iPad, the Face ID prompt. They are in
`docs/DEVICE_TEST_PLAN.md`.
