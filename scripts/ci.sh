#!/bin/bash
# The checks that would run on CI, run here instead.
#
# This account's GitHub Actions are billing-locked, so the workflow from #6
# cannot start. The checks themselves are worth having either way, so they
# live here: run it before pushing, and the release script runs it too.
#
#   scripts/ci.sh              # quick: skips the disk-walking tests
#   SYSDATA_SCAN_TESTS=1 scripts/ci.sh   # everything, minutes not seconds
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# Snapshot the compiled string tables before anything regenerates them.
# build-app.sh below runs compile-strings.sh itself, so a check placed after
# it can never fail — which is what this one used to do.
strings_before=$(mktemp -d)
trap 'rm -rf "$strings_before"' EXIT
cp -R Sources/SysDataMenu/Resources/*.lproj "$strings_before/"

step "Toolchain"
swift --version

step "Build"
swift build -c release

step "Test"
if [ -n "${SYSDATA_SCAN_TESTS:-}" ]; then
  echo "including the disk-walking tests"
else
  echo "skipping the disk-walking tests; set SYSDATA_SCAN_TESTS=1 to include them"
fi
swift test

step "Shell scripts"
shellcheck sysdata scripts/*.sh

step "Assemble the app bundle"
scripts/build-app.sh

step "Check the bundle is complete"
app="build/System Data Unpacked.app"
test -x "$app/Contents/MacOS/SysDataMenu"
test -f "$app/Contents/Info.plist"
# Bundle.module reads this; without it the app aborts on its first localized
# string, which is how it shipped broken once already.
test -d "$app/Contents/Resources/SysDataMenu_SysDataMenu.bundle"
# The widget and the Shortcuts actions live in files SwiftPM does not make;
# build-app.sh writes both, and a bundle without them still launches fine,
# which is exactly why it is checked.
test -x "$app/Contents/PlugIns/SysDataWidget.appex/Contents/MacOS/SysDataWidget"
grep -q "FreeSafeItemsIntent" "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
codesign --verify --deep --strict "$app"
architectures=$(lipo -archs "$app/Contents/MacOS/SysDataMenu")
case "$architectures" in
  *arm64*x86_64*|*x86_64*arm64*) echo "universal: $architectures" ;;
  *) echo "built for $architectures only; Intel Macs cannot run this" >&2; exit 1 ;;
esac
# Every slice must claim the SDK it was built with and still launch on
# macOS 14. A binary that records sdk 14.0 gets the old controls on current
# macOS without a single warning, which is how 1.2.1 and earlier shipped.
expected_sdk=$(xcrun --sdk macosx --show-sdk-version)
build_versions=$(vtool -show-build "$app/Contents/MacOS/SysDataMenu")
if printf '%s\n' "$build_versions" | awk '$1 == "sdk" && $2 != "'"$expected_sdk"'" { bad = 1 } END { exit !bad }'; then
  echo "binary does not record SDK $expected_sdk:" >&2; printf '%s\n' "$build_versions" >&2; exit 1
fi
if printf '%s\n' "$build_versions" | awk '$1 == "minos" && $2 != "14.0" { bad = 1 } END { exit !bad }'; then
  echo "binary no longer runs on macOS 14:" >&2; printf '%s\n' "$build_versions" >&2; exit 1
fi
echo "sdk $expected_sdk, minos 14.0"

step "Check the compiled strings are up to date"
# compile-strings.sh regenerates the .strings tables from the catalogue; a
# catalogue edit saved without them shows up here rather than as a
# half-translated menu at runtime.
#
# The comparison is against the snapshot taken at the top of this script, not
# against git: asking git would fail on any uncommitted resource change, which
# is exactly the state this script is meant to be run in.
for table in "$strings_before"/*.lproj/Localizable.strings; do
  language=$(basename "$(dirname "$table")")
  cmp -s "$table" "Sources/SysDataMenu/Resources/$language/Localizable.strings" \
    || { echo "$language/Localizable.strings is stale; run scripts/compile-strings.sh" >&2; exit 1; }
done

step "Check the site's llms files are up to date"
# docs/llms.txt and docs/llms-full.txt are generated from README.md, so a
# README edit without a regeneration ships a stale description of the app.
scripts/make-llms.sh --check

printf '\n\033[1;32m==> everything passed\033[0m\n'
