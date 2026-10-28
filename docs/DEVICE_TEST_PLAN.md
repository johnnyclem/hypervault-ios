# Trying it on a real phone

The simulator and CI cover the screens, the state machines and the Kit. They cannot cover the things below:
a real Google or Apple sign-in, Face ID, the microphone, the camera, widgets on a Home Screen, the share
sheet from another app, Siri, and an Apple Intelligence model. This is the checklist for those, in the order
that finds problems fastest. Each line says what should happen.

## Before you start

1. **Server.** Make sure the deployment you test against includes
   [hypervault#180](https://github.com/johnnyclem/hypervault/pull/180) (the keys, invite and admin
   routes accept the app's bearer token; on an older deployment those screens show the server's own refusal,
   which is correct but not what you want to test) and
   [hypervault#181](https://github.com/johnnyclem/hypervault/pull/181) (Google sign-in's way back to the app).
   Production deploys from `main`, but a CLI deploy from an older checkout replaces it; look at the newest
   production deployment's commit before testing.
2. **Google's way back.** `curl -sI 'https://hypervault.store/auth/callback?client=app&code=x'` must answer `302`
   with `location: hypervault://auth/callback?code=x`. Nothing needs adding to Supabase's Redirect URLs: the app
   returns through the website's own callback, which Supabase already accepts. The app makes this same request
   before it opens Google and says so if it fails.
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
- **Google:** the sheet opens, you sign in, the sheet closes by itself and you land in the app (or on the
  waitlist if the account is not approved). If the sheet ends on the website's login page, with a line about a
  stale sign-in cookie, the site has no `client=app` handling (step 2); the app should have said so before
  opening the sheet, so tell me if it did not.
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
- **Pairing link:** put `hypervault://pair?code=BCDF-2346` in a note and tap it. Agent keys opens with the website's
  `/pair` page over it in Safari, the code in the link; the app never offers to approve. Sign in on the page if it
  asks, and closing it returns to Agent keys.

## 4. Lock

- Settings > Lock with Face ID. Background and reopen: the lock appears before anything else.
- Open a sheet (for example Connect an agent), background the app, reopen: the lock covers the sheet.
- The app switcher card is blank.
- With the lock on, widgets show a placeholder and Siri keeps queue until you unlock.
- VoiceOver on: nothing behind the lock can be reached.
- The words say what it is: the lock screen says "HyperVault is locked" and "Unlock to continue.", and a passcode
  opens it as well as Face ID.
- **Lock off, a screen with a value:** Vault > Add, pick Card, type a number, then open the app switcher: the card is
  the blank one with the mark, not the form. The same for the Replace and Edit sheets, a freshly made agent key, a
  page password (one just made, and one typed into New password before Create password) and a webhook's signing secret. Come back: the form is as you left it, and nothing asks for Face ID,
  even after a minute away. Look at the card with the keyboard up: the system keyboard may still be drawn on it.
- **Reinstall:** sign in, delete the app, install it again: the first launch shows the way in, not your account. An
  update over the older build keeps you signed in. The widgets and the share sheet, used before the app is opened
  again, say to sign in.

## 5. Features that need a live account

Work through the Account menu (the avatar on Home), Yours (the panel in Home's corner) and the You tab with a real approved
account and a few kept things: Library (from the Account menu or Yours, More; list and graph, open a
page, share it, edit its source), Memory (search, ask, graph, a branch and a merge), Chat (a conversation with
a connected model, a room), Agent keys (Connect an agent, make a key and copy it: the paste is gone after a
minute and never reaches another device; revoke a key: Revoke, then Really revoke?), Logins, cards & keys
(add one; its value is never shown again), Mail, Truth, Task boards, Tools (add an MCP server), Import (a
ChatGPT export zip), Domain, and Appearance (the website's theme: choose one and see it on the website; the app does not change). Anything that shows the server's own refusal on a session-only route means the deployment predates #180.

### The tabs and the You tab, on a device

A simulator and a unit test cannot show how these look or behave at the edges, and a person who built the tabs has not seen
them on glass (handoff 2.3, 4.1, 9):

- **The tab bar.** Four tabs, Home, Chat, Memory and You, in that order, with house, bubble, brain and person symbols. The
  one that is showing is in the sky-blue accent, the others are quiet; the bar floats over the content with the system's
  glass, and a list scrolled under it is readable through it. Check it with Reduce Transparency on and with the text size
  at the largest accessibility size (the labels must not be cut off).
- **The You tab on a phone is one stack.** It opens on the Vault with the list of seven panes one step back (the back
  button reads "You"). Open every pane from the list in turn, going back each time: General (Email, Plan, Sign out, and
  "On this phone"), Vault, Agent keys, Models, Domain, Appearance, Import. Each must load its content (the plan line
  fills in, the keys and models lists fill in) rather than stay on a spinner. This is the one a NavigationSplitView in its
  compact width got wrong in CI, so the app uses a navigation stack on a phone: if a pane shows a spinner for more than a
  few seconds after you have been through two or three others, that is a bug.
- **Choose the open pane again.** Go back to the list and choose the pane that was open: it opens again from its first
  screen, not where you left it.
- **Account & keys, and links.** The Account menu's "Account & keys" row, `hypervault://vault/account?tab=keys` and
  `hypervault://vault/account#appearance` (opened from Notes or Safari, not from a page) each land on the right pane of
  the You tab. `hypervault://tab/yours` opens Home
  with the Yours panel up, and `hypervault://tab/canvas` opens Home.
- **The Account menu.** The avatar on Home opens it as a sheet with a Close button; a row closes it and goes there, on the
  tab that has it (Library on Home, Mail, Truth, Tools, Dreams on the tab that owns them). Admin is there only for an
  admin. Sign out with something waiting in the outbox asks first. At the largest text size the list scrolls to Sign out.
- **Appearance says it is the website's.** Choosing a theme changes your dashboard on the website and nothing in the app:
  open the website to see it, and check the app's own look did not change.
- **iPad.** At a regular width the You tab shows its list of panes beside the open pane (the open one highlighted), and
  the tabs stay a tab bar with no sidebar of their own. Rotate the iPad and use Split View and Slide Over so that the
  width goes from regular to compact and back: the layout changes between the two, the open pane stays open, and what had
  been pushed on it comes along. This was not run on an iPad by the person who built it.

### The Vault, on a device

A render and a unit test cannot show these, and each one decides a line of the code (handoff 4.5, 4.6):

- **The allow switch waits for the server.** Vault > an entry > Allowed keys: turn a switch on. A spinner stands where
  the switch was until the server answers, and the switch then comes back on. Turn airplane mode on and turn a switch:
  it comes back where it was, and the line under the switches says "Network hiccup. That did not go through. Try
  again." Watch for a thumb that moves before the answer comes: if one does, the spinner is not taking the switch's
  place fast enough.
- **Paste, then edit, a long key.** Add > Key: paste a 60-character token into Value, tap away, tap back and fix one
  character. iOS clears a secure field on the first key after it gets focus back. If the token is wiped, the eye
  beside the field is the way to check what was typed, and whether it stays is the owner's call.
- **No Passwords bar on a key.** Add > Key, tap Value: there is no Passwords suggestion bar and no "Suggest strong
  password". If one appears, the field needs a UITextField with no content type.
- **No Save Password.** Add > Login, type a username and a password, Save: iOS must not offer to save the password to
  iCloud Keychain. If it does, the Username and Password fields lose their `.username` and `.password` content types.
- **A taken name moves the cursor.** Add a login with a name that is already used: the server's line is under Name, the
  cursor is in the Name field, and with VoiceOver on, VoiceOver is too.
- **The line under the form is polite.** With VoiceOver on, type a card number that fails its checksum and leave the
  field: the line is read after a short pause, behind whatever VoiceOver is saying, and a failed Save is read at once.
- **An entry is a sheet.** Vault > an entry opens at half height with the grabber showing; drag it up to full height and
  back down, and Close dismisses it. With the text size at the largest accessibility size the half-height sheet still
  scrolls to everything, and Rename and Replace the value open over it.
- **Closing keeps what was typed.** Add > Login, type a username and swipe the sheet down: it stays. Close asks
  "Discard what you typed?", and Keep editing returns to the form. The same for Rename and Replace the value. Back,
  next to Close, asks the same while something is typed (and the edge swipe from the left does nothing), and with nothing
  typed it is the system's Back. With the network slow, tap Save and then Close: Close is off until the answer comes.

## 6. Needs special hardware or settings

- **On-device chat** needs an Apple Intelligence device with the model downloaded: Chat > Models should say it is
  available, and a conversation should stream with no network.
- **A model on your network** (Ollama or LM Studio): allow the local network prompt; the phone calls it directly.
- **iPad:** the tab bar stays a tab bar (no sidebar of the tabs), and the You tab shows its list of panes beside the pane; rotate and use Split View with a sheet open.

## 7. Accessibility pass

Turn on VoiceOver and go through sign-in, the canvas and a list: every control is named, results are
announced (a kept card, an error, a copied key), and nothing is only colour. Set the text size to the largest
accessibility size: filters become menus, rows wrap, nothing is cut off. Turn on Reduce Motion: the thinking
dots, launch mark and skeletons stay still.

Please note anything that looks or behaves wrong; the renders in `snapshots-claude-ios-client` show what
each screen is meant to look like.
