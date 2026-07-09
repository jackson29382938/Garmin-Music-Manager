.PHONY: build run app app-debug app-signed rebuild clean

build:
	swift build

run:
	swift run

# Package a release .app bundle into ./dist (ad-hoc sign, bundle libmtp)
app:
	./Scripts/package-app.sh

# Package a debug .app bundle into ./dist
app-debug:
	./Scripts/package-app.sh --debug

# Rebuild the app bundle from scratch into ./dist
rebuild:
	./rebuild-app.sh

# Developer ID sign (set CODESIGN_IDENTITY). Optional: NOTARIZE=1 NOTARY_PROFILE=…
app-signed:
	@test -n "$$CODESIGN_IDENTITY" || (echo "Set CODESIGN_IDENTITY first" >&2; exit 1)
	./Scripts/package-app.sh

clean:
	swift package clean
	rm -rf dist
