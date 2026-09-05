#!/bin/bash
# Builds a release binary and wraps it in a minimal .app bundle so it can be
# added to Login Items or moved to /Applications.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
name="SysDataMenu"
bundle="$root/build/$name.app"

swift build -c release --package-path "$root"

binary=$(swift build -c release --package-path "$root" --show-bin-path)/$name
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/$name"

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
	<string>0.1.0</string>
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
  codesign --force --sign "$identity" --identifier local.sysdata.menu "$bundle"
  echo "Signed with: $identity"
else
  codesign --force --sign - "$bundle"
  echo "warning: no code-signing certificate found; ad-hoc signed." >&2
  echo "         Privacy grants will reset on every rebuild." >&2
fi
echo "Built $bundle"
