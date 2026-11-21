SOURCES := App/Sources App/UITests Core/Sources Core/Tests Core/Package.swift
# First paired iPhone on the cable, unless DEVICE_ID is given.
DEVICE_ID ?= $(shell xcrun devicectl list devices 2>/dev/null | grep 'available (paired)' \
	| grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)
# Bundle ID from Config/Local.xcconfig (see Config/Local.xcconfig.example).
BUNDLE_ID ?= $(shell sed -n 's/^CANOPY_BUNDLE_ID *= *//p' Config/Local.xcconfig 2>/dev/null)
APP := build/Build/Products/Debug-iphoneos/Canopy.app

.PHONY: check format format-check lint project build build-signed test e2e corpus need-device device pull-spike hooks \
	archive testflight

## Everything that must pass before a build goes to a phone.
check: format-check lint build test corpus

format:
	swift format --in-place --recursive --configuration .swift-format $(SOURCES)

format-check:
	swift format lint --strict --recursive --configuration .swift-format $(SOURCES)

lint:
	swiftlint lint --strict --quiet

project:
	xcodegen generate --quiet

## Compile for iOS without signing, so `check` works without an Apple developer account.
build: project
	xcodebuild -quiet -project Canopy.xcodeproj -scheme Canopy -destination 'generic/platform=iOS' \
		-derivedDataPath build CODE_SIGNING_ALLOWED=NO build

## Signed build for a real phone (needs Config/Local.xcconfig).
build-signed: project
	xcodebuild -quiet -project Canopy.xcodeproj -scheme Canopy -destination 'generic/platform=iOS' \
		-derivedDataPath build -allowProvisioningUpdates build

test:
	cd Core && swift test --quiet

## E2E smoke suite (S-01…S-08), on demand before shipping a build. Not part of `check`.
SIM ?= iPhone 17
e2e: project
	xcodebuild -quiet -project Canopy.xcodeproj -scheme Canopy -destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath build test

## T7.1 corpus replay. No corpus exists yet: this target says so instead of pretending to pass.
corpus:
	@if [ -d corpus ] && [ -n "$$(ls corpus 2>/dev/null)" ]; then \
		echo "corpus/ has files but corpus tests are not written yet (T7.1)"; exit 1; \
	else echo "corpus: no captures yet (T7.1 not started) — skipped"; fi

need-device:
	@[ -n "$(DEVICE_ID)" ] || { echo "No paired iPhone available. Plug it in and unlock it, or set DEVICE_ID."; exit 1; }
	@[ -n "$(BUNDLE_ID)" ] || { echo "Set CANOPY_BUNDLE_ID in Config/Local.xcconfig."; exit 1; }

## Build, install and launch on the cabled iPhone.
device: need-device build-signed
	xcrun devicectl device install app --device $(DEVICE_ID) $(APP)
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing $(BUNDLE_ID)

## Copy spike captures off the phone into spike-data/.
pull-spike: need-device
	mkdir -p spike-data
	xcrun devicectl device copy from --device $(DEVICE_ID) --domain-type appDataContainer \
		--domain-identifier $(BUNDLE_ID) --source Documents/spike --destination spike-data

## Release archive for TestFlight. Build number is the UTC time, so every upload is unique.
TEAM_ID ?= $(shell sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null)
BUILD_NUMBER ?= $(shell date -u +%Y%m%d%H%M)
ARCHIVE := build/Canopy.xcarchive

archive: project
	@[ -n "$(TEAM_ID)" ] || { echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig."; exit 1; }
	rm -rf $(ARCHIVE)
	xcodebuild -quiet -project Canopy.xcodeproj -scheme Canopy -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath build -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) archive

## Upload the archive to App Store Connect. Needs the app record to exist there first.
testflight: check archive
	sed 's/TEAM_ID/$(TEAM_ID)/' Config/ExportOptions.plist > build/ExportOptions.plist
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist build/ExportOptions.plist \
		-exportPath build/export -allowProvisioningUpdates

hooks:
	install -m 755 scripts/pre-commit .git/hooks/pre-commit
