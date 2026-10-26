#!/bin/bash
# Makes a simulator quiet enough for the UI tests: no "slide to type" introduction over the keyboard, no autocorrect
# turning a typed word into another, and Reduce Motion on, so the screens that animate all the time (the aurora
# behind the canvas, the floating cards of the welcome story) hold still and the app can go idle between taps.
#
#     scripts/prepare_ui_simulator.sh <udid>
#
# The device is booted to write the settings and shut down again. Unknown keys are harmless; they are ignored.
set -euo pipefail

udid="${1:?usage: prepare_ui_simulator.sh <simulator udid>}"

xcrun simctl bootstatus "$udid" -b >/dev/null
write() { xcrun simctl spawn "$udid" defaults write "$@" || echo "could not write $*"; }

write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
write com.apple.Preferences KeyboardAutocorrection -bool false
write com.apple.Preferences KeyboardPrediction -bool false
write com.apple.Preferences KeyboardShowPredictionBar -bool false
write com.apple.Preferences KeyboardAutocapitalization -bool false
write com.apple.Preferences KeyboardCheckSpelling -bool false
write com.apple.Preferences KeyboardPeriodShortcut -bool false
write com.apple.Accessibility ReduceMotionEnabled -bool true

xcrun simctl shutdown "$udid"
echo "Prepared simulator $udid for the UI tests."
