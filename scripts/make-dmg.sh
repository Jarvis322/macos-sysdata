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

command -v uvx >/dev/null || { echo "uvx is required (brew install uv)" >&2; exit 1; }

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# Until 1.0.4 the in-app updater looked inside the image for its own file
# name, SysDataMenu.app. A hidden copy under that name lets those versions
# still update; the next update from the new version moves the install to the
# new name. The copy is the same signed bundle, so nothing about the checks
# changes, and Finder does not show it. Those updaters copy the hidden flag
# along with it, so the app clears the flag on its own bundle at launch
# (Updater.unhide); without that, an update left it missing from Finder.
# dmg-settings.py hides it in the image.
legacy="$staging/$name.app"
cp -R "$app" "$legacy"

# The window people see when the image opens: the app on the left, an arrow,
# Applications on the right. Drawn at both scales and joined into one TIFF so
# it stays sharp on Retina displays.
swift "$root/scripts/make-dmg-background.swift" 1 "$staging/background.png"
swift "$root/scripts/make-dmg-background.swift" 2 "$staging/background@2x.png"
tiffutil -cathidpicheck "$staging/background.png" "$staging/background@2x.png" \
  -out "$staging/background.tiff" 2>/dev/null

[ -f "$root/assets/AppIcon.icns" ] || "$root/scripts/make-icon.sh"

rm -f "$dmg"
# dmgbuild writes the Finder layout into the image directly, so this needs no
# Finder scripting, no GUI session and no Automation permission. Pinned: the
# layout format is its code, not ours.
uvx --from dmgbuild==1.6.7 dmgbuild \
  -s "$root/scripts/dmg-settings.py" \
  -D app="$app" \
  -D legacy="$legacy" \
  -D background="$staging/background.tiff" \
  -D volume_icon="$root/assets/AppIcon.icns" \
  "$volume" "$dmg"

# dmgbuild ignores a failed copy, so the image is checked rather than trusted:
# the app is there and still validly signed, the legacy copy is there and
# hidden, and Applications points where it should.
mount=$(mktemp -d)
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" >/dev/null
check_image() {
  codesign --verify --deep --strict "$mount/$app_name.app" &&
  [ -d "$mount/$name.app" ] &&
  GetFileInfo -a "$mount/$name.app" | grep -q V &&
  [ "$(readlink "$mount/Applications")" = "/Applications" ] &&
  [ -f "$mount/.background.tiff" ]
}
if check_image; then image_ok=1; else image_ok=0; fi
hdiutil detach "$mount" -quiet
rmdir "$mount"
[ "$image_ok" = 1 ] || { echo "the disk image is incomplete: $dmg" >&2; exit 1; }

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
