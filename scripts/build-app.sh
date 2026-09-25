#!/bin/bash
# Builds a release binary and wraps it in a minimal .app bundle so it can be
# added to Login Items or moved to /Applications.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# The SwiftPM product and the executable inside the bundle keep the original
# name, so `SysDataMenu --json` in anyone's scripts still works. The bundle
# itself carries the app's name, which is what Finder and Spotlight show.
name="SysDataMenu"
app_name="System Data Unpacked"
version=$(tr -d "[:space:]" < "$root/VERSION")
bundle="$root/build/$app_name.app"
archive="$root/build/$name-$version.zip"

# Keep in step with Package.swift's platforms.
minimum_macos="14.0"
sdk_version=$(xcrun --sdk macosx --show-sdk-version)

"$root/scripts/compile-strings.sh"
# Universal: macOS 14 still runs on Intel Macs, and a single-architecture
# build silently excludes every one of them.
#
# The linker is told the SDK version outright. SwiftPM's default build system
# records the deployment target there instead (sdk 14.0), and macOS decides
# from that field which behaviour an app was built for: an app that claims the
# macOS 14 SDK keeps the macOS 14 controls on macOS 26 and later, next to
# every other app on the system in the current design.
build_flags=(-c release --package-path "$root" --arch arm64 --arch x86_64
  -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_macos" -Xlinker "$sdk_version")
swift build "${build_flags[@]}"

bin_path=$(swift build "${build_flags[@]}" --show-bin-path)
binary="$bin_path/$name"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/$name"
architectures=$(lipo -archs "$binary")
case "$architectures" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "warning: built for $architectures only; Intel Macs cannot run this." >&2 ;;
esac
# Bundle.module looks for the SwiftPM resource bundle next to the main bundle's
# resources; without it the app aborts on its first localized string.
cp -R "$bin_path/${name}_${name}.bundle" "$bundle/Contents/Resources/"

# Shortcuts finds an app's actions through Metadata.appintents, which Xcode
# writes with appintentsmetadataprocessor and SwiftPM does not. The same tool
# is run here on the same inputs: the sources and the constant values the
# compiler recorded for them. Without it the intents compile and nothing in
# Shortcuts ever lists them.
intents_work=$(mktemp -d)
# The newest set: .build keeps the outputs of earlier build systems beside
# the current one.
# Only the app's own module: the widget and the snapshot library are built
# alongside it and have constant values of their own.
const_values=$(find "$root/.build" -path "*/Release/$name-p.build/Objects-normal/arm64/*.swiftconstvalues" -print0 2>/dev/null \
  | xargs -0 ls -t 2>/dev/null | head -1)
[ -n "$const_values" ] || { echo "no compiler constant values found for App Intents" >&2; exit 1; }
find "$root/Sources/SysDataMenu" -name "*.swift" > "$intents_work/sources.txt"
printf '%s\n' "$const_values" > "$intents_work/const-values.txt"
xcrun appintentsmetadataprocessor \
  --output "$intents_work" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name "$name" \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --platform-family macOS \
  --deployment-target "$minimum_macos" \
  --target-triple "arm64-apple-macos$minimum_macos" \
  --source-file-list "$intents_work/sources.txt" \
  --swift-const-vals-list "$intents_work/const-values.txt" \
  --force --quiet-warnings >/dev/null 2>&1
[ -f "$intents_work/Metadata.appintents/extract.actionsdata" ] \
  || { echo "appintentsmetadataprocessor wrote no metadata" >&2; exit 1; }
cp -R "$intents_work/Metadata.appintents" "$bundle/Contents/Resources/"
rm -rf "$intents_work"

# The desktop widget, as an app extension inside the app. SwiftPM builds it
# as a plain executable; the bundle around it is what makes it an extension.
widget="$bundle/Contents/PlugIns/SysDataWidget.appex"
mkdir -p "$widget/Contents/MacOS"
cp "$bin_path/SysDataWidget" "$widget/Contents/MacOS/SysDataWidget"
cat > "$widget/Contents/Info.plist" <<WIDGET
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>SysDataWidget</string>
	<key>CFBundleIdentifier</key>
	<string>local.sysdata.menu.widget</string>
	<key>CFBundleName</key>
	<string>SysDataWidget</string>
	<key>CFBundleDisplayName</key>
	<string>System Data</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>$minimum_macos</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
WIDGET

[ -f "$root/assets/AppIcon.icns" ] || "$root/scripts/make-icon.sh"
cp "$root/assets/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"

# The bundle identifier never changes: macOS keys Full Disk Access, the
# preferences and the login item to it, and a new one would reset all three.
#
# The interface strings live in the SwiftPM resource bundle, and macOS only
# matches its .lproj folders against the user's languages when the main
# bundle declares its own localizations (reproduced on macOS 27.0: without
# this list every language but English falls back to the English keys).
# Generated from the .lproj folders so it cannot drift from the catalog.
localizations=$(for d in "$root/Sources/SysDataMenu/Resources/"*.lproj; do
  basename "$d" .lproj
done | sort | sed 's|^|\t\t<string>|; s|$|</string>|')
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
	<key>CFBundleLocalizations</key>
	<array>
$localizations
	</array>
	<key>CFBundleName</key>
	<string>Unpacked</string>
	<key>CFBundleDisplayName</key>
	<string>$app_name</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>$minimum_macos</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleAllowMixedLocalizations</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

# The translations live in a nested SwiftPM bundle. Declare its languages on
# the main app too, so macOS does not constrain resource lookup to English.
# Derive the list from the packaged tables so new translations stay in sync.
plist="$bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$plist"
for localization in "$bundle/Contents/Resources/${name}_${name}.bundle/Contents/Resources/"*.lproj; do
  language=$(basename "$localization" .lproj)
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $language" "$plist"
done

# macOS remembers privacy grants (Full Disk Access, folder access) by the
# app's designated requirement. An ad-hoc signature is a cdhash that changes
# on every build, so grants would be forgotten each time. A real certificate
# gives a stable identity: prefer Developer ID, then Apple Development.
identity=${CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null)
  for kind in "Developer ID Application" "Apple Development"; do
    # `|| true`: grep exits 1 when the kind is absent, which would abort the
    # script under `set -e` before the next kind is tried.
    identity=$(printf '%s\n' "$identities" | grep -oE "\"${kind}[^\"]*\"" | head -1 | tr -d '"' || true)
    [ -n "$identity" ] && break
  done
fi

if [ -n "$identity" ]; then
  # Inside out: the extension is sealed first, then the app around it. Both
  # carry the team-prefixed app group the widget reads the last scan from.
  codesign --force --options runtime --timestamp --sign "$identity" \
    --entitlements "$root/scripts/entitlements/widget.entitlements" "$widget"
  codesign --force --options runtime --timestamp --sign "$identity" --identifier local.sysdata.menu \
    --entitlements "$root/scripts/entitlements/app.entitlements" "$bundle"
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
