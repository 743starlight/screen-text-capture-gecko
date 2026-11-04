
.PHONY: build test lint
build:
	xcodebuild -project screentextcapture.xcodeproj -scheme screentextcapture -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- build
test:
	xcodebuild -project screentextcapture.xcodeproj -scheme screentextcapture -derivedDataPath build CODE_SIGN_IDENTITY=- test
lint:
	xcrun swiftc -frontend -parse screentextcapture/*.swift screentextcaptureTests/*.swift
	plutil -lint screentextcapture/Info.plist screentextcapture.xcodeproj/project.pbxproj
	git diff --check
