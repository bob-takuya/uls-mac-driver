# ULS Laser Control for macOS
# Makefile

# Compiler and flags
CC = clang
OBJC = clang
CFLAGS = -Wall -Wextra -O2 -g -I./include
OBJCFLAGS = -Wall -Wextra -O2 -g -I./include -fobjc-arc
FRAMEWORKS = -framework Cocoa -framework IOKit -framework CoreFoundation -framework UniformTypeIdentifiers -framework QuartzCore

# Directories
SRC_DIR = src
INCLUDE_DIR = include
BUILD_DIR = build
APP_DIR = $(BUILD_DIR)/ULSLaserControl.app
CONTENTS_DIR = $(APP_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources

# Source files
C_SOURCES = $(SRC_DIR)/uls_usb.c $(SRC_DIR)/uls_job.c
OBJC_SOURCES = $(SRC_DIR)/main.m $(SRC_DIR)/ULSAppDelegate.m $(SRC_DIR)/ULSMainWindowController.m $(SRC_DIR)/ULSSVGParser.m

# Object files
C_OBJECTS = $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(C_SOURCES))
OBJC_OBJECTS = $(patsubst $(SRC_DIR)/%.m,$(BUILD_DIR)/%.o,$(OBJC_SOURCES))
OBJECTS = $(C_OBJECTS) $(OBJC_OBJECTS)

# Output
EXECUTABLE = ULSLaserControl
TARGET = $(MACOS_DIR)/$(EXECUTABLE)

# CLI tool
CLI_SOURCES = $(SRC_DIR)/uls_usb.c $(SRC_DIR)/uls_job.c
CLI_TARGET = $(BUILD_DIR)/uls-cli

.PHONY: all clean app cli test install

all: app cli

# Build macOS app bundle
app: $(TARGET) $(CONTENTS_DIR)/Info.plist $(RESOURCES_DIR)/AppIcon.icns

$(TARGET): $(OBJECTS) | $(MACOS_DIR)
	$(OBJC) $(OBJCFLAGS) $(FRAMEWORKS) -o $@ $(OBJECTS)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.m | $(BUILD_DIR)
	$(OBJC) $(OBJCFLAGS) -c -o $@ $<

# Create directories
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(MACOS_DIR):
	mkdir -p $(MACOS_DIR)

$(RESOURCES_DIR):
	mkdir -p $(RESOURCES_DIR)

# Info.plist
$(CONTENTS_DIR)/Info.plist: | $(CONTENTS_DIR)
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $@
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $@
	@echo '<plist version="1.0">' >> $@
	@echo '<dict>' >> $@
	@echo '    <key>CFBundleDevelopmentRegion</key>' >> $@
	@echo '    <string>en</string>' >> $@
	@echo '    <key>CFBundleExecutable</key>' >> $@
	@echo '    <string>$(EXECUTABLE)</string>' >> $@
	@echo '    <key>CFBundleIconFile</key>' >> $@
	@echo '    <string>AppIcon</string>' >> $@
	@echo '    <key>CFBundleIdentifier</key>' >> $@
	@echo '    <string>com.uls.lasercontrol</string>' >> $@
	@echo '    <key>CFBundleInfoDictionaryVersion</key>' >> $@
	@echo '    <string>6.0</string>' >> $@
	@echo '    <key>CFBundleName</key>' >> $@
	@echo '    <string>ULS Laser Control</string>' >> $@
	@echo '    <key>CFBundlePackageType</key>' >> $@
	@echo '    <string>APPL</string>' >> $@
	@echo '    <key>CFBundleShortVersionString</key>' >> $@
	@echo '    <string>1.0</string>' >> $@
	@echo '    <key>CFBundleVersion</key>' >> $@
	@echo '    <string>1</string>' >> $@
	@echo '    <key>LSMinimumSystemVersion</key>' >> $@
	@echo '    <string>11.0</string>' >> $@
	@echo '    <key>NSHighResolutionCapable</key>' >> $@
	@echo '    <true/>' >> $@
	@echo '    <key>NSPrincipalClass</key>' >> $@
	@echo '    <string>NSApplication</string>' >> $@
	@echo '    <key>CFBundleDocumentTypes</key>' >> $@
	@echo '    <array>' >> $@
	@echo '        <dict>' >> $@
	@echo '            <key>CFBundleTypeName</key>' >> $@
	@echo '            <string>SVG Document</string>' >> $@
	@echo '            <key>CFBundleTypeRole</key>' >> $@
	@echo '            <string>Viewer</string>' >> $@
	@echo '            <key>LSItemContentTypes</key>' >> $@
	@echo '            <array>' >> $@
	@echo '                <string>public.svg-image</string>' >> $@
	@echo '            </array>' >> $@
	@echo '        </dict>' >> $@
	@echo '        <dict>' >> $@
	@echo '            <key>CFBundleTypeName</key>' >> $@
	@echo '            <string>PDF Document</string>' >> $@
	@echo '            <key>CFBundleTypeRole</key>' >> $@
	@echo '            <string>Viewer</string>' >> $@
	@echo '            <key>LSItemContentTypes</key>' >> $@
	@echo '            <array>' >> $@
	@echo '                <string>com.adobe.pdf</string>' >> $@
	@echo '            </array>' >> $@
	@echo '        </dict>' >> $@
	@echo '    </array>' >> $@
	@echo '</dict>' >> $@
	@echo '</plist>' >> $@

$(CONTENTS_DIR):
	mkdir -p $(CONTENTS_DIR)

# Placeholder icon (in real app, use proper icon file)
$(RESOURCES_DIR)/AppIcon.icns: | $(RESOURCES_DIR)
	@touch $@

# Command line tool
cli: $(CLI_TARGET)

$(CLI_TARGET): $(SRC_DIR)/uls_cli.c $(CLI_SOURCES) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -framework IOKit -framework CoreFoundation -o $@ $^

# Test program
test: $(BUILD_DIR)/test_uls
	./$(BUILD_DIR)/test_uls

$(BUILD_DIR)/test_uls: $(SRC_DIR)/test_uls.c $(C_SOURCES) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -framework IOKit -framework CoreFoundation -o $@ $^

# Install to /Applications
install: app
	cp -R $(APP_DIR) /Applications/

# Clean build files
clean:
	rm -rf $(BUILD_DIR)

# Help
help:
	@echo "ULS Laser Control for macOS"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build both app and CLI (default)"
	@echo "  app      - Build macOS application"
	@echo "  cli      - Build command-line tool"
	@echo "  test     - Build and run tests"
	@echo "  install  - Install app to /Applications"
	@echo "  clean    - Remove build files"
	@echo "  help     - Show this help"
