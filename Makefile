APP_NAME  := RedOS
BUNDLE_ID ?= dev.redos.RedOS
SIGN_ID   ?= RedOS Development
CONFIG    ?= release
SYSTEM_ONE_MODEL ?= gemma4:e4b-it-qat
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

.PHONY: all build app sign run install test test-live lint format clean cert models localjev localjev-run

all: app

build:
	swift build -c $(CONFIG)

app: build
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BIN_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/"
	cp Resources/Info.plist "$(PLIST)"
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(PLIST)"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(PLIST)"
	plutil -replace CFBundleVersion -string "$(BUILD)" "$(PLIST)"
	cp -R Resources/Localization/*.lproj "$(CONTENTS)/Resources/"
	@$(MAKE) --no-print-directory sign

# A stable identity keeps macOS privacy permissions across rebuilds; ad-hoc resets them.
sign:
	@if security find-identity -p codesigning | grep -q "$(SIGN_ID)"; then \
		codesign --force --sign "$(SIGN_ID)" "$(APP)"; \
	else \
		echo "warning: identity '$(SIGN_ID)' not found, using ad-hoc signature (run 'make cert')"; \
		codesign --force --sign - "$(APP)"; \
	fi

run: app
	-pkill -x $(APP_NAME)
	open "$(APP)"

install: app
	-pkill -x $(APP_NAME)
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" /Applications/
	open "/Applications/$(APP_NAME).app"

test:
	swift test $(TEST_FLAGS)

# Needs a running Ollama with $(SYSTEM_ONE_MODEL).
test-live:
	REDOS_LIVE_MODEL=$(SYSTEM_ONE_MODEL) swift test $(TEST_FLAGS) --filter LiveSystemOneTests

models:
	ollama pull $(SYSTEM_ONE_MODEL)

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
