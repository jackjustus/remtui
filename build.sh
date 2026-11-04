#!/bin/sh
# Builds remtui. The Info.plist is embedded into the binary so macOS
# can show the Reminders permission prompt for a plain CLI tool.
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 main.swift -o remtui \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
echo "built ./remtui"
