# Xcode Cloud

Xcode Cloud can build the app, run its unit tests and send an archive to TestFlight. What lives in this repository is what a
workflow needs from it; the workflow itself is made once, by you, in Xcode (it is stored in App Store Connect, not in Git).

GitHub Actions stays the gate for pull requests: it runs the Kit's tests on Linux and the thirteen UI-test jobs. Xcode Cloud
is the part that ships.

| | GitHub Actions (`.github/workflows/ios.yml`) | Xcode Cloud |
| --- | --- | --- |
| Kit tests (Linux) | yes | no (the Kit is built as part of the app; its own tests run only here) |
| App unit tests | yes | yes (`HyperVaultCloud` scheme) |
| UI tests, snapshots | yes (thirteen jobs) | no: they would use the 25 free monthly compute hours in a few runs |
| Signed archive, TestFlight | no | yes |

## What is in the repository

- `ci_scripts/ci_post_clone.sh`: Xcode Cloud runs it after cloning. `HyperVault.xcodeproj` is generated from `project.yml`
  (the copy in Git is stale on purpose, see `docs/HANDOFF.md`), so the script installs XcodeGen with Homebrew and runs
  `xcodegen generate` before Xcode Cloud looks for the scheme. It also writes `Config/Local.xcconfig` from the workflow's
  environment (below). Run it on a Mac the same way: `CI_PRIMARY_REPOSITORY_PATH=$PWD ci_scripts/ci_post_clone.sh`; a
  `Local.xcconfig` that is already there is left alone.
- The `HyperVaultCloud` scheme in `project.yml`: the app, its extensions and the unit tests (no UI tests); the archive is
  the Release configuration. Xcode Cloud needs a shared scheme, and XcodeGen's are.
- `Config/Local.xcconfig` is now in `.gitignore`. `Config/Base.xcconfig` always said it was not committed, but nothing ignored it.
- A step in the GitHub Actions `app` job runs the script as Xcode Cloud does and checks that the project it makes has the
  scheme and has taken the team and the bundle id prefix.

## Setting it up (once)

You need the Apple Developer Program (it includes 25 Xcode Cloud compute hours a month), Xcode 26, an App Store Connect app
(see "Which bundle id" below), and admin on the GitHub repository.

1. `make open` (generates the project and opens it). In Xcode: **Product ▸ Xcode Cloud ▸ Create Workflow**, product
   *HyperVault*. Xcode asks to install the Xcode Cloud GitHub app on `johnnyclem/hypervault-ios`; allow it.
2. **Workflow "Tests"**: Environment: Xcode *Latest Release* (the app needs the iOS 26 SDK), macOS *Latest Release*.
   Start condition: *Pull Request Changes* to `main` (add *Branch Changes* on `main` if you want it after merges too).
   Action: *Test*, scheme `HyperVaultCloud`, platform iOS, a current iPhone simulator. Nothing else is needed: the
   simulator is not signed.
3. **Workflow "TestFlight"** (when the bundle id below is settled): Start condition: *Branch Changes* on `main` (or a tag
   pattern if you would rather ship by tagging). Action: *Archive*, scheme `HyperVaultCloud`, platform iOS, Deployment
   Preparation *TestFlight (Internal Testing Only)*.
4. **Environment variables** (the workflow's *Environment* section, not secret): `DEVELOPMENT_TEAM` only if the team of the
   App Store Connect app is not the workflow's own (otherwise `CI_TEAM_ID` is used); `HV_BUNDLE_PREFIX` when it is not
   `store.hypervault`. The Tests workflow needs neither.
5. Start a build by hand and read the *Post-Clone* log first. It should end with `Generated HyperVault.xcodeproj`.

## Which bundle id

The app is `<HV_BUNDLE_PREFIX>.app`, the share extension `<prefix>.app.share`, the widgets `<prefix>.app.widgets`, the app
group `group.<prefix>.app` and the keychain group `<prefix>.shared` (`Config/Base.xcconfig`). The prefix is
`store.hypervault` unless a `Local.xcconfig` says otherwise, and every one of those has to be registered under the team,
with Sign in with Apple, App Groups, Keychain Sharing and Associated Domains on the app's id.

The Xcode project that is tracked in Git carries a device-only override that `project.yml` cannot say: the app's bundle id
for iPhones is `com.clem.hypervault`, not `<prefix>.app`. Xcode Cloud builds from `project.yml`, so it does not see that
override. Two ways out, and only you can choose:

- Make the App Store Connect app `<prefix>.app` (for example `store.hypervault.app`, if `store.hypervault` is yours to
  register, which `Config/Base.xcconfig` says to check) and set `HV_BUNDLE_PREFIX` to match in the workflow.
- Keep `com.clem.hypervault`. Then `project.yml` needs one setting for the app's id that the extensions' ids are built from
  (`HV_APP_ID`, defaulting to `<prefix>.app`), set in the workflow. That is a small change to make once you say so.

Either way, the first archive is where the signing is proved. Whether Xcode Cloud's managed signing can switch on the
capabilities for an id that has never been built from your Mac is not something to assume: build and run once from Xcode with
the same id, so that Xcode has registered them, and read the archive's log if it complains.

## What was not checked

There is no Mac or Apple account where this was written. The script's logic was run on Linux with stand-ins for Homebrew and
XcodeGen, the YAML was parsed, and GitHub Actions checks the generated project; nothing here has run in Xcode Cloud. The first
build is the test. If it fails before any compiling, the Post-Clone log is where to look; if the project is not found, the
script did not leave `HyperVault.xcodeproj` where `CI_PRIMARY_REPOSITORY_PATH` points.

Apple's references: [Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts),
[Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference).
