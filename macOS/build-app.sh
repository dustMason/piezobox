#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_root="$repo_root/macOS"
output_root="$repo_root/build"
app_path="$output_root/Piezo Scope.app"

swift build --package-path "$package_root" -c release
binary_root="$(swift build --package-path "$package_root" -c release --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_root/PiezoScope" "$app_path/Contents/MacOS/PiezoScope"
cp "$package_root/Info.plist" "$app_path/Contents/Info.plist"
rm -f "$app_path/Contents/Resources/PiezoAudio.pkg"
swift "$package_root/tools/make-icon.swift" "$output_root/AppIcon.iconset"
iconutil -c icns "$output_root/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_path"
echo "Built: $app_path"
