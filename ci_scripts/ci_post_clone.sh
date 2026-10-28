#!/bin/sh
# Xcode Cloud runs this after it clones the repository (docs/XCODE_CLOUD.md).
#
# HyperVault.xcodeproj is generated from project.yml by XcodeGen, and the copy in the repository is not kept up to date, so
# the project a workflow builds is made here. What is yours rather than the project's (your team, your bundle id prefix)
# comes from the workflow's environment into Config/Local.xcconfig, the file the checked-in xcconfigs include and git
# ignores.
#
# It can be run on a Mac the same way: `CI_PRIMARY_REPOSITORY_PATH=$PWD ci_scripts/ci_post_clone.sh`. A Local.xcconfig that
# is already there is left alone.

set -eu

# Xcode Cloud runs the script with ci_scripts as the working directory.
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"

if ! command -v xcodegen >/dev/null 2>&1; then
    # Homebrew's own update and cleanup would add minutes to a run that is billed by the hour. It is retried: a download
    # that fails on one try often works on the next.
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
    attempt=1
    until brew install xcodegen; do
        if [ "$attempt" -ge 3 ]; then
            echo "error: could not install XcodeGen with Homebrew" >&2
            exit 1
        fi
        attempt=$((attempt + 1))
        sleep 10
    done
fi

if [ -e Config/Local.xcconfig ]; then
    echo "Config/Local.xcconfig is already there; leaving it as it is."
else
    # DEVELOPMENT_TEAM and HV_BUNDLE_PREFIX are set in the workflow's Environment section when they are needed (an archive
    # for TestFlight needs both to be the ones the App Store Connect app was made with). The team falls back to the one
    # the workflow belongs to. The simulator the tests run on needs no signature, as in GitHub Actions.
    team="${DEVELOPMENT_TEAM:-${CI_TEAM_ID:-}}"
    {
        echo "// Written by ci_scripts/ci_post_clone.sh for this build. Not committed."
        if [ -n "$team" ]; then echo "DEVELOPMENT_TEAM = $team"; fi
        if [ -n "${HV_BUNDLE_PREFIX:-}" ]; then echo "HV_BUNDLE_PREFIX = $HV_BUNDLE_PREFIX"; fi
        echo "CODE_SIGNING_ALLOWED[sdk=iphonesimulator*] = NO"
    } > Config/Local.xcconfig
    echo "Wrote Config/Local.xcconfig:"
    sed 's/^/    /' Config/Local.xcconfig
fi

xcodegen generate

if [ ! -d HyperVault.xcodeproj ]; then
    echo "error: XcodeGen did not make HyperVault.xcodeproj" >&2
    exit 1
fi
echo "Generated HyperVault.xcodeproj"
