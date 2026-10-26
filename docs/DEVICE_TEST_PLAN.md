# Trying it on a real phone

The simulator and CI cover the screens, the state machines and the Kit. They cannot cover the things below:
a real Google or Apple sign-in, Face ID, the microphone, the camera, widgets on a Home Screen, the share
sheet from another app, Siri, and an Apple Intelligence model. This is the checklist for those, in the order
that finds problems fastest. Each line says what should happen.

## Before you start

1. **Server.** Merge [hypervault#180](https://github.com/johnnyclem/hypervault/pull/180) (or point the app at
   its Vercel preview in Settings > Advanced). Without it the keys, invite, pairing and admin screens show the
   server's own refusal, which is correct but not what you want to test.
2. **Supabase redirect.** Add `hypervault://auth/callback` to the project's redirect allow-list
   (Authentication > URL Configuration). Without it Google sign-in lands on the site URL instead of the app.
3. **Apple sign-in** (optional). The production project had the Apple provider off when this was written, so the
   button is hidden; turn it on, with the app's bundle ID in the authorized client IDs, to test it.
4. **Build.** `cp Config/Local.xcconfig.example Config/Local.xcconfig`, put your `DEVELOPMENT_TEAM` in it,
   `make open`, run the `HyperVault` scheme on a device. App Groups, Keychain sharing and Sign in with Apple
   need a paid team; see `project.yml` for what to remove with a free one.
5. **Contract checks** (no phone needed), in `Packages/HyperVaultKit`:
   - `HV_LIVE_SERVER=https://hypervault.store swift test --filter LiveServerTests` reads the real launch path
     with no credentials (it has been run and passes).
   - `scripts/e2e/start.sh` then `swift test --filter 'LocalServerE2ETests|LocalE2E'` runs 89 signed-in tests
     against a local copy of the web app with throwaway people (see [LOCAL_E2E.md](LOCAL_E2E.md)); it has been
     run and passes, and covers the session-only routes, mail, vault secrets, truth, task boards, tools and import.
   - `HV_E2E_SERVER=https://hypervault.store HV_E2E_KEY=<an API key from your vault> swift test --filter LiveAuthenticatedTests`
     reads about twenty authenticated endpoints with your own key (GET only, counts printed, never content) and
     checks that the Kit keeps every row the server sent. It has not been run yet; start here.

## 1. First run

- Open the app signed out: the four-page story plays; Skip and "I already have an account" go to sign-in.
- **Google:** the sheet opens, you sign in, you land in the app (or on the waitlist if the account is not
  approved). If you land on the website instead, the redirect URL in step 2 is missing.
- **Email code:** a six-digit code arrives, entering it signs you in; a wrong code says so in words.
- **Waitlist:** an unapproved account sees the waitlist; pasting a valid invite code lets it in at once.
- Kill and reopen the app: you are still signed in, with no flash of the story.
- Sign out, reopen: the way in comes first, not the story.

## 2. Keep, and the canvas

- Paste a long block of text: it stages as a chip with Keep it / Ask instead. Keep it: a card with the link, a
  light haptic, and (the first time only) confetti.
- Type "show my memories": cards appear. "Hide that": they go.
- Dictate (microphone button): words appear as you speak; leaving the tab stops listening.
- Scan a page (the plus menu): the recognised text lands in the field.
- Turn Airplane Mode on and keep something: it says it will wait. Turn it off: it is kept.

## 3. From outside the app

- **Share sheet:** share text and a link from Safari and Notes; it keeps and shows the link. Offline, it saves
  and the app keeps it on next open (Settings shows "Waiting to keep" until then).
- **Widgets:** add the Home Screen and Lock Screen widgets; they show recent things, never keys. Keep
  something and the widget updates.
- **Siri / Shortcuts:** "Keep this in HyperVault" with text.
- **Spotlight:** search a page's name from the Home Screen; tapping opens it in the app. Keys never appear.

## 4. Lock

- Settings > Lock with Face ID. Background and reopen: the lock appears before anything else.
- Open a sheet (for example Connect an agent), background the app, reopen: the lock covers the sheet.
- The app switcher card is blank.
- With the lock on, widgets show a placeholder and Siri keeps queue until you unlock.
- VoiceOver on: nothing behind the lock can be reached.

## 5. Features that need a live account

Work through the You tab with a real approved account and a few kept things: Library (list and graph, open a
page, share it, edit its source), Memory (search, ask, graph, a branch and a merge), Chat (a conversation with
a connected model, a room), Account & keys (Connect an agent, make and revoke a key), Logins, cards & keys
(add one; its value is never shown again), Mail, Truth, Task boards, Tools (add an MCP server), Import (a
ChatGPT export zip), Your address. Anything that says it needs the server to allow it is waiting on #180.

## 6. Needs special hardware or settings

- **On-device chat** needs an Apple Intelligence device with the model downloaded: Chat > Models should say it is
  available, and a conversation should stream with no network.
- **A model on your network** (Ollama or LM Studio): allow the local network prompt; the phone calls it directly.
- **iPad:** the sidebar replaces the tab bar; rotate and use Split View with a sheet open.

## 7. Accessibility pass

Turn on VoiceOver and go through sign-in, the canvas and a list: every control is named, results are
announced (a kept card, an error, a copied key), and nothing is only colour. Set the text size to the largest
accessibility size: filters become menus, rows wrap, nothing is cut off. Turn on Reduce Motion: the thinking
dots, launch mark and skeletons stay still.

Please note anything that looks or behaves wrong; the renders in `snapshots-claude-ios-client` show what
each screen is meant to look like.
