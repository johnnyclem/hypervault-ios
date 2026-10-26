# Everyday commands. `make help` lists them.

SIM ?= platform=iOS Simulator,name=iPhone 16

.PHONY: help project test-kit build test open clean icon

help:
	@echo "make project   Generate HyperVault.xcodeproj from project.yml (needs xcodegen)"
	@echo "make test-kit  Run the HyperVaultKit unit tests (works on macOS and Linux)"
	@echo "make build     Build the app for the simulator"
	@echo "make test      Run the app's unit tests on the simulator"
	@echo "make open      Generate the project and open it in Xcode"
	@echo "make icon      Redraw the app icon"

project:
	xcodegen generate

test-kit:
	cd Packages/HyperVaultKit && swift test

build: project
	xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination '$(SIM)' \
	  CODE_SIGNING_ALLOWED=NO build | xcpretty || true

test: project
	xcodebuild -project HyperVault.xcodeproj -scheme HyperVault -destination '$(SIM)' \
	  CODE_SIGNING_ALLOWED=NO test

open: project
	open HyperVault.xcodeproj

icon:
	python3 scripts/make_icon.py

clean:
	rm -rf HyperVault.xcodeproj Config/Generated DerivedData .build Packages/HyperVaultKit/.build
