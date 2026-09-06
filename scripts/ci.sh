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
app="build/SysDataMenu.app"
test -x "$app/Contents/MacOS/SysDataMenu"
test -f "$app/Contents/Info.plist"
# Bundle.module reads this; without it the app aborts on its first localized
# string, which is how it shipped broken once already.
test -d "$app/Contents/Resources/SysDataMenu_SysDataMenu.bundle"
codesign --verify --deep --strict "$app"
architectures=$(lipo -archs "$app/Contents/MacOS/SysDataMenu")
case "$architectures" in
  *arm64*x86_64*|*x86_64*arm64*) echo "universal: $architectures" ;;
  *) echo "built for $architectures only; Intel Macs cannot run this" >&2; exit 1 ;;
esac

step "Check the compiled strings are up to date"
# compile-strings.sh regenerates the .strings tables from the catalogue; a
# catalogue edit committed without them shows up here rather than as a
# half-translated menu at runtime.
scripts/compile-strings.sh >/dev/null
git diff --exit-code -- Sources/SysDataMenu/Resources \
  || { echo "the compiled strings are stale; commit the regenerated files" >&2; exit 1; }

printf '\n\033[1;32m==> everything passed\033[0m\n'
