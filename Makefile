APP_NAME := EasyFind
CONFIG ?= release
BUILD_DIR := .build/$(CONFIG)
APP_BUNDLE := $(APP_NAME).app

.PHONY: build run test clean install uninstall

build:
	swift build -c $(CONFIG)
	rm -rf easyfind.app $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/EasyFindApp $(APP_BUNDLE)/Contents/MacOS/EasyFind
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --deep --sign - $(APP_BUNDLE)
	plutil -lint $(APP_BUNDLE)/Contents/Info.plist

run: build
	open $(APP_BUNDLE)

install:
	./install.sh

uninstall:
	./install.sh --uninstall

test:
	swift test

clean:
	rm -rf .build $(APP_BUNDLE)