#!/bin/bash
# Wraps the built app in a disk image: the app, a link to /Applications, and
# the drag between them that every Mac user already knows.
#
# Run scripts/build-app.sh first. With NOTARY_PROFILE set, the image is
# notarized and stapled in its own right, so the download opens cleanly even
# before Gatekeeper has seen the app inside it.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
name="SysDataMenu"
app_name="System Data Unpacked"
version=$(tr -d "[:space:]" < "$root/VERSION")
app="$root/build/$app_name.app"
# The image keeps its old file name: release pages, the cask and anyone's
# download script already point at it.
dmg="$root/build/$name-$version.dmg"
volume="$app_name $version"

[ -d "$app" ] || { echo "missing $app; run scripts/build-app.sh first" >&2; exit 1; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"

# Until 1.0.4 the in-app updater looked inside the image for its own file
# name, SysDataMenu.app. A hidden copy under that name lets those versions
# still update; the next update from the new version moves the install to the
# new name. The copy is the same signed bundle, so nothing about the checks
# changes, and Finder does not show it. Those updaters copy the hidden flag
# along with it, so the app clears the flag on its own bundle at launch
# (Updater.unhide); without that, an update left it missing from Finder.
cp -R "$app" "$staging/$name.app"
chflags hidden "$staging/$name.app"

# The volume takes the app's own icon, so the mounted disk is recognisable in
# the Finder sidebar rather than a generic white drive.
if [ -f "$root/assets/AppIcon.icns" ]; then
  cp "$root/assets/AppIcon.icns" "$staging/.VolumeIcon.icns"
  SetFile -a C "$staging" 2>/dev/null || true
fi

rm -f "$dmg"
hdiutil create -volname "$volume" -srcfolder "$staging" -ov -format ULFO -quiet "$dmg"

# The image is signed with the same identity as the app; an unsigned image
# around a signed app still warns on download.
identity=${CODESIGN_IDENTITY:-}
if [ -z "$identity" ]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
fi
if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
  echo "Signed the image with: $identity"
else
  echo "warning: no Developer ID found; the image is unsigned." >&2
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  echo "Notarized and stapled the image"
fi

echo "Built $dmg"
