# Everyday commands. `make help` lists them.

SIM ?= platform=iOS Simulator,name=iPhone 16

.PHONY: help project tokens check-tokens test-kit build test test-unit test-ui open clean icon

help:
	@echo "make project   Generate HyperVault.xcodeproj from project.yml (needs xcodegen)"
	@echo "make tokens    Regenerate the colour catalog and HVTokens from docs/brand/tokens.json"
	@echo "make check-tokens  Fail if they are out of step with it"
	@echo "make test-kit  Run the HyperVaultKit unit tests (works on macOS and Linux)"
	@echo "make build     Build the app for the simulator"
	@echo "make test      Run the app's unit tests and UI tests on the simulator"
	@echo "make test-unit Run only the app's unit tests"
	@echo "make test-ui   Run only the UI tests: the whole app launched and driven on a simulator"
	@echo "make open      Generate the project and open it in Xcode"
	@echo "make icon      Cut the app icon from docs/app-icon-source.png"

project:
	xcodegen generate

tokens:
	python3 scripts/gen_tokens.py

check-tokens:
	python3 scripts/gen_tokens.py --check

test-kit:
	cd Packages/HyperVaultKit && swift test

build: project
	xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination '$(SIM)' \
	  CODE_SIGNING_ALLOWED=NO build | xcpretty || true

test: project
	xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination '$(SIM)' \
	  CODE_SIGNING_ALLOWED=NO test

test-unit: project
	xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination '$(SIM)' \
	  CODE_SIGNING_ALLOWED=NO -skip-testing:HyperVaultUITests test

test-ui: project
	xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination '$(SIM)' \
	  CODE_SIGNING_ALLOWED=NO -only-testing:HyperVaultUITests test

open: project
	open HyperVault.xcodeproj

icon:
	python3 scripts/make_icon.py

clean:
	rm -rf HyperVault.xcodeproj Config/Generated DerivedData .build Packages/HyperVaultKit/.build
