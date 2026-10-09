APP_NAME  := RedOS
BUNDLE_ID ?= dev.redos.RedOS
SIGN_ID   ?= RedOS Development
CONFIG    ?= release
SYSTEM_ONE_MODEL ?= gemma4:e4b-it-qat
EXTRACTION_MODEL ?= gemma4:e2b-it-qat
LOCALJEV_PORT    ?= 8080
VERSION   := $(shell cat VERSION)
BUILD     := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

BIN_DIR    = $(shell swift build -c $(CONFIG) --show-bin-path)
APP       := build/$(APP_NAME).app
CONTENTS  := $(APP)/Contents
PLIST     := $(CONTENTS)/Info.plist

# Without Xcode, Swift Testing and SourceKit live in the Command Line Tools (whose _Testing_Foundation overlay is empty).
DEV_DIR       := $(shell xcode-select -p)
TOOLCHAIN_DIR := $(if $(findstring CommandLineTools,$(DEV_DIR)),$(DEV_DIR),$(DEV_DIR)/Toolchains/XcodeDefault.xctoolchain)
TESTING_FW    := $(DEV_DIR)/Library/Developer/Frameworks
TEST_FLAGS    := $(if $(findstring CommandLineTools,$(DEV_DIR)),-Xswiftc -F -Xswiftc $(TESTING_FW) -Xlinker -F -Xlinker $(TESTING_FW) -Xlinker -rpath -Xlinker $(TESTING_FW) -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)

.PHONY: all build app sign run install release publish test test-live test-live-copilot eval lint format clean cert models ollama-tune localjev localjev-run

all: app

build:
	swift build -c $(CONFIG)

app: build
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Frameworks"
	cp "$(BIN_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/"
	install_name_tool -add_rpath @executable_path/../Frameworks "$(CONTENTS)/MacOS/$(APP_NAME)" 2>/dev/null
	ditto "$(BIN_DIR)/Sparkle.framework" "$(CONTENTS)/Frameworks/Sparkle.framework"
	# Not sandboxed: Sparkle's XPC services are unused.
	rm -rf "$(CONTENTS)/Frameworks/Sparkle.framework/XPCServices" \
		"$(CONTENTS)/Frameworks/Sparkle.framework/Versions/B/XPCServices"
	cp Resources/Info.plist "$(PLIST)"
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(PLIST)"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(PLIST)"
	plutil -replace CFBundleVersion -string "$(BUILD)" "$(PLIST)"
	cp -R Resources/Localization/*.lproj "$(CONTENTS)/Resources/"
	cp -R Resources/DiagramDesign "$(CONTENTS)/Resources/"
	@$(MAKE) --no-print-directory sign

# A stable identity keeps macOS privacy permissions across rebuilds; ad-hoc resets them.
# Sparkle's helpers are signed inside out with the same identity (no hardened runtime: self-signed
# certificates have no Team ID, so library validation would reject the framework).
sign:
	@ID="$(SIGN_ID)"; \
	if ! security find-identity -p codesigning | grep -q "$(SIGN_ID)"; then \
		echo "warning: identity '$(SIGN_ID)' not found, using ad-hoc signature (run 'make cert')"; ID=-; \
	fi; \
	FW="$(CONTENTS)/Frameworks/Sparkle.framework"; \
	codesign --force --sign "$$ID" "$$FW/Versions/B/Autoupdate" && \
	codesign --force --sign "$$ID" "$$FW/Versions/B/Updater.app" && \
	codesign --force --sign "$$ID" "$$FW" && \
	codesign --force --sign "$$ID" "$(APP)"

run: app
	-pkill -x $(APP_NAME)
	open "$(APP)"

install: app
	-pkill -x $(APP_NAME)
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	open "/Applications/$(APP_NAME).app"

# Release: `make release` (zip + dmg, EdDSA signature, appcast item), then `make publish`
# (GitHub release + appcast push). CHANNEL=beta for pre-releases.
CHANNEL ?=
release:
	@git diff --quiet HEAD || { echo "error: commit your changes first"; exit 1; }
	@security find-identity -p codesigning | grep -q "$(SIGN_ID)" || \
		{ echo "error: '$(SIGN_ID)' is required: updates must keep the same signature"; exit 1; }
	@$(MAKE) --no-print-directory app CONFIG=release
	scripts/release.sh "$(VERSION)" "$(BUILD)" "$(CHANNEL)"

publish:
	scripts/publish.sh "$(VERSION)" "$(CHANNEL)"

test:
	swift test $(TEST_FLAGS)

# Needs a running Ollama with $(SYSTEM_ONE_MODEL).
test-live:
	REDOS_LIVE_MODEL=$(SYSTEM_ONE_MODEL) swift test $(TEST_FLAGS) --filter LiveSystemOneTests

# System Two through GitHub Copilot CLI (uses your Copilot subscription).
COPILOT_MODEL ?= claude-haiku-5.5
test-live-copilot:
	REDOS_COPILOT_PATH="$$(zsh -ilc 'command -v copilot' 2>/dev/null | tail -1)" REDOS_COPILOT_MODEL=$(COPILOT_MODEL) \
		swift test $(TEST_FLAGS) --filter LiveCopilotTests

models:
	ollama pull $(SYSTEM_ONE_MODEL)
	ollama pull $(EXTRACTION_MODEL)

# Two cache slots per model: System One and System Two prompts stop evicting each other (~1.8 s -> ~0.15 s).
# `brew services restart ollama` regenerates the plist: run this again afterwards.
OLLAMA_PLIST := $(HOME)/Library/LaunchAgents/sh.brew.ollama.plist
ollama-tune:
	/usr/libexec/PlistBuddy -c "Delete :EnvironmentVariables:OLLAMA_NUM_PARALLEL" "$(OLLAMA_PLIST)" 2>/dev/null || true
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OLLAMA_NUM_PARALLEL string 2" "$(OLLAMA_PLIST)"
	launchctl bootout gui/$$(id -u)/sh.brew.ollama 2>/dev/null || true
	sleep 2
	launchctl bootstrap gui/$$(id -u) "$(OLLAMA_PLIST)"

# System One accuracy, safety and latency on eval/commands.jsonl; EVAL_FLAGS e.g. --no-chain.
eval:
	swift run -c release RedOSEval --model $(SYSTEM_ONE_MODEL) --extract-model $(EXTRACTION_MODEL) \
		--out eval/runs/$$(date +%Y%m%d-%H%M%S)-$(subst :,_,$(SYSTEM_ONE_MODEL)).jsonl $(EVAL_FLAGS)

# Optional Jev-compatible backend; RedOS uses it when the `systemOne.jevURL` default is set.
localjev:
	rm -rf build/localjev-src && mkdir -p build
	cp -R Vendor/localjev/src build/localjev-src
	patch -s -p2 -d build/localjev-src < Vendor/patches/localjev-upstream-extra-body.patch
	bun build build/localjev-src/index.ts --compile --minify \
		--no-compile-autoload-dotenv --no-compile-autoload-bunfig --outfile build/localjev

localjev-run: localjev
	LOCALJEV_UPSTREAM=http://127.0.0.1:11434 LOCALJEV_UPSTREAM_MODEL=$(SYSTEM_ONE_MODEL) \
	LOCALJEV_UPSTREAM_EXTRA_BODY='{"reasoning_effort":"none"}' LOCALJEV_PORT=$(LOCALJEV_PORT) build/localjev

lint:
	TOOLCHAIN_DIR=$(TOOLCHAIN_DIR) swiftlint --strict

format:
	swift format --in-place --recursive Sources Tests Package.swift

cert:
	scripts/create-dev-cert.sh "$(SIGN_ID)"

clean:
	rm -rf .build build
