#!/bin/bash
# Converts the SVG icon to PNG and generates all platform launcher icons.
# Requires: npx (Node.js), flutter_launcher_icons (dev dependency)

set -e
cd "$(dirname "$0")/.."

echo "Converting SVG to PNG..."
npx --yes sharp-cli -i assets/app_icon.svg -o assets/app_icon.png resize 1024 1024

echo "Generating launcher icons..."
dart run flutter_launcher_icons

echo "Done!"
