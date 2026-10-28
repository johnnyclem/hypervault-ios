# Xcode Cloud

Xcode Cloud can build the app, run its unit tests and archive it for TestFlight. This repository holds what a workflow needs
from it. The workflow itself is made once, by you, in Xcode (it is stored in App Store Connect, not in Git), and one choice has
to be made before that: the app's bundle id (below).

Nothing here has run in Xcode Cloud. See "What was not checked".

GitHub Actions stays the gate for pull requests. Xcode Cloud is the part that ships.

| | GitHub Actions (`.github/workflows/ios.yml`) | Xcode Cloud |
| --- | --- | --- |
| Kit tests (Linux) | yes | no (the Kit is built as part of the app; its own tests run only in GitHub Actions) |
| App unit tests | yes | yes (`HyperVaultCloud` scheme) |
| Snapshot renders | yes, and the PNGs are published | they run as unit tests; nothing publishes them |
| UI tests | yes (thirteen jobs) | no: they would use the 25 free monthly compute hours in a few runs |
| Release build for a device | yes (unsigned, compile only) | yes, as the archive, signed |
| TestFlight | no | yes (a post-action) |

## What is in the repository

- `ci_scripts/ci_post_clone.sh`: Xcode Cloud runs it after cloning. `HyperVault.xcodeproj` is generated from `project.yml`
  (the copy in Git is stale on purpose, see `docs/HANDOFF.md`), so the script installs XcodeGen with Homebrew and runs
  `xcodegen generate` so that the project exists when the workflow builds. It also writes `Config/Local.xcconfig` from the
  workflow's environment (below). A `Local.xcconfig` that is already there is left alone, so the script can be run on a Mac
  with `CI_PRIMARY_REPOSITORY_PATH=$PWD ci_scripts/ci_post_clone.sh`; like `make project` it regenerates the tracked
  `HyperVault.xcodeproj` and `Config/Generated`, which git can put back.
- The `HyperVaultCloud` scheme in `project.yml`: the app, its extensions and the unit tests (no UI tests). Its archive is the
  Release configuration. Xcode Cloud needs a shared scheme with the archive action, and XcodeGen's are shared.
- `Config/Local.xcconfig` is in `.gitignore` now. `Config/Base.xcconfig` always said it was not committed, but nothing ignored it.
- Three checks at the end of the GitHub Actions `app` job: the hook is run as Xcode Cloud runs it and the project it makes is
  checked for the scheme, the team and the bundle id; `xcodebuild -describeAllArchivableProducts` (what Xcode uses to find the
  products to offer) is run on it; and the Release configuration is built for a device, unsigned. Nothing else builds Release,
  so without that the first archive would also be its first compile.

## Decide first: the bundle id

Xcode Cloud ties a workflow's product to an App Store Connect app record by bundle id, and a product has exactly one. Even a
workflow that only runs tests needs the record: Xcode finds the one with that id, or helps you make it. So this is the first
step, not the last.

The app is `<HV_BUNDLE_PREFIX>.app`, the share extension `<prefix>.app.share`, the widgets `<prefix>.app.widgets`, the app group
`group.<prefix>.app` and the keychain group `<TeamID>.<prefix>.shared` (`Config/Base.xcconfig`, `project.yml`). The prefix is
`store.hypervault` unless a `Local.xcconfig` says otherwise (`Config/Local.xcconfig.example` says to change it only if
`store.hypervault` is not yours to register). All of those ids have to be registered under the team, and the app's,
the share extension's and the widgets' need App Groups and Keychain Sharing; the app's also needs Sign in with Apple and
Associated Domains.

The Xcode project that is tracked in Git has a device-only bundle id for the app, `com.clem.hypervault`, set in the project and
never moved into `project.yml`. Xcode Cloud builds from `project.yml`, so it does not see that. There are two ways out, and
only you can choose:

- Make the App Store Connect app `<prefix>.app` (for example `store.hypervault.app`) and set `HV_BUNDLE_PREFIX` to the prefix in
  the workflow.
- Keep `com.clem.hypervault`. Then `project.yml` needs a setting for the app's id that the extensions' ids are built from, and
  which ids you have registered for them decides what it should say. Tell me which and I will make that change.

## Setting it up (once)

You need the Apple Developer Program (it includes 25 Xcode Cloud compute hours a month), Xcode 26, your Apple Account added in
Xcode's Settings, XcodeGen on the Mac (`brew install xcodegen`, for `make open`), the role to create an app record (App Manager,
Admin or Account Holder) and to grant Xcode Cloud access to `johnnyclem/hypervault-ios` (an organization owner, or admin on a
personal repository).

1. `make open` generates the project and opens it. Because the bundle id comes from an `.xcconfig` file, Apple asks for an extra
   step first: in the project editor, **Signing & Capabilities**, set the app target's bundle identifier to the id you chose, as
   plain text. That edit is in the generated project only; do not commit it.
2. In the **Report navigator**, click the **Cloud** tab and **Get Started**. Pick the *HyperVault* product, let Xcode make or find
   the app record, and grant access to the repository (this installs the Xcode Cloud GitHub app). Apple's tip is to keep the
   first workflow simple: in its editor choose the scheme `HyperVaultCloud` and make the action **Test** (an iPhone simulator;
   nothing is signed), with *Latest Release* for Xcode and macOS (the app needs the iOS 26 SDK). Keep the suggested start
   conditions (the default branch, and pull requests to it) or narrow them.
3. Start the first build. Read the **Post-Clone** log first; it should end with `Generated HyperVault.xcodeproj`. Xcode relies on
   the explicit bundle id to show workflows and builds, and with an `.xcconfig` id it may not: App Store Connect (the app's
   **Xcode Cloud** tab) always does.
4. Once that passes, add what ships. **Archive** with scheme `HyperVaultCloud`, platform iOS, on pushes to `main` (or on a tag
   pattern), and a **TestFlight Internal Testing** post-action for a group that you make in App Store Connect. Distributing to
   external testers also needs a clean build.
5. **Environment variables** (the workflow's *Environment* section; none are secret): `HV_BUNDLE_PREFIX` when the prefix is not
   `store.hypervault`, and `DEVELOPMENT_TEAM` only when the team of the app record is not the workflow's own (otherwise
   `CI_TEAM_ID` is used). Set them on every workflow, the Test one too: they decide the bundle id the project is generated
   with, and it has to be the product's.

## What was not checked

There is no Mac or Apple account where this was written. The hook's logic was run on Linux with stand-ins for Homebrew and
XcodeGen, the YAML was parsed, and GitHub Actions runs the hook and checks the project it makes on the next push. Nothing has run in
Xcode Cloud. The things most likely to go wrong, in order:

- **The generated project.** Apple says Xcode Cloud "requires a consistent Xcode project or workspace that's continuously
  present", and that with a third-party tool that generates or edits it, "the initial configuration of Xcode Cloud and
  subsequent builds may fail". Generating in a post-clone script is the usual way to use XcodeGen with Xcode Cloud, and the
  tracked project is there for the initial configuration, but whether this works is known only from the first build. If it does
  not, the fallback is to commit the generated project and keep it current with `make project`; that first needs the team and
  the device bundle id moved from the tracked project into `project.yml`, which `docs/HANDOFF.md` describes.
- **The first archive.** It signs with Xcode Cloud's managed signing. Whether that can switch on the capabilities for ids that
  have never been built from your Mac is not something to assume: build and run once from Xcode with the same ids first, so
  that Xcode has registered them. GitHub Actions compiles Release for a device unsigned, so a compile error should not be what
  the archive finds, but signing and entitlements are only proved there.
- **The workflow editor.** The names above are from Apple's documentation; the editor's own wording may differ.

Apple's references: [Configuring your first Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow),
[Setting up your project to use Xcode Cloud](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud),
[Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts),
[Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference),
[Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference).
