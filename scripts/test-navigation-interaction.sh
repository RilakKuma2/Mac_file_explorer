#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
cd "$PROJECT_DIR"
swift build
BUILD_DIR="$(swift build --show-bin-path)"
NAV_TEST_DIR="$(mktemp -d /tmp/mac-explorer-navigation-check.XXXXXX)"
nav_objects=("$BUILD_DIR"/MacExplorer.build/*.o)
nav_objects=(${nav_objects:#*/main.swift.o})
xcrun swiftc -g -I "$BUILD_DIR/Modules" \
    "$SCRIPT_DIR/test-navigation-interaction.swift" "${nav_objects[@]}" \
    -o "$NAV_TEST_DIR/NavigationInteractionCheck"
"$NAV_TEST_DIR/NavigationInteractionCheck"
