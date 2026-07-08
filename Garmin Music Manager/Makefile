.PHONY: build run app app-debug clean

build:
	swift build

run:
	swift run

# Package a release .app bundle into ./dist
app:
	./Scripts/package-app.sh

# Package a debug .app bundle into ./dist
app-debug:
	./Scripts/package-app.sh --debug

clean:
	swift package clean
	rm -rf dist
