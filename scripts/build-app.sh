#!/bin/bash
# Builds a release binary and wraps it in a minimal .app bundle so it can be
# added to Login Items or moved to /Applications.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
name="SysDataMenu"
version=$(tr -d "[:space:]" < "$root/VERSION")
bundle="$root/build/$name.app"
archive="$root/build/$name-$version.zip"

"$root/scripts/compile-strings.sh"
swift build -c release --package-path "$root"

bin_path=$(swift build -c release --package-path "$root" --show-bin-path)
binary="$bin_path/$name"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/$name"
# Bundle.module looks for the SwiftPM resource bundle next to the main bundle's
# resources; without it the app aborts on its first localized string.
cp -R "$bin_path/${name}_${name}.bundle" "$bundle/Contents/Resources/"

[ -f "$root/assets/AppIcon.icns" ] || "$root/scripts/make-icon.sh"
cp "$root/assets/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"

cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$name</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>local.sysdata.menu</string>
	<key>CFBundleName</key>
	<string>System Data</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

# macOS remembers privacy grants (Full Disk Access, folder access) by the
# app's designated requirement. An ad-hoc signature is a cdhash that changes
# on every build, so grants would be forgotten each time. A real certificate
# gives a stable identity: prefer Developer ID, then Apple Development.
identity=${CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null)
  for kind in "Developer ID Application" "Apple Development"; do
    identity=$(printf '%s\n' "$identities" | grep -oE "\"${kind}[^\"]*\"" | head -1 | tr -d '"')
    [ -n "$identity" ] && break
  done
fi

if [ -n "$identity" ]; then
  codesign --force --options runtime --timestamp --sign "$identity" --identifier local.sysdata.menu "$bundle"
  echo "Signed with: $identity"
else
  codesign --force --sign - "$bundle"
  echo "warning: no code-signing certificate found; ad-hoc signed." >&2
  echo "         Privacy grants will reset on every rebuild." >&2
fi

# Optional notarization, so a downloaded copy opens without a Gatekeeper
# warning. Store credentials once with:
#   xcrun notarytool store-credentials sysdata --apple-id ... --team-id ...
# then run: NOTARY_PROFILE=sysdata scripts/build-app.sh
ditto -c -k --keepParent --norsrc "$bundle" "$archive"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$bundle"
  ditto -c -k --keepParent --norsrc "$bundle" "$archive"
  echo "Notarized and stapled"
fi
echo "Built $bundle"
echo "Archive $archive"
