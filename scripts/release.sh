#!/bin/bash
# One-command release: bump VERSION, test, build a notarized .app, commit,
# tag, push, publish the GitHub release and update the Homebrew cask.
#
#   scripts/release.sh            # patch: 0.3.2 -> 0.3.3
#   scripts/release.sh minor      # 0.3.2 -> 0.4.0
#   scripts/release.sh major      # 0.3.2 -> 1.0.0
#
# Needs: gh (logged in), a notarytool keychain profile (NOTARY_PROFILE,
# default "sysdata") and push access to the tap repository.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
part=${1:-patch}
repo="Jarvis322/macos-sysdata"
tap_repo="Jarvis322/homebrew-tap"
cask="sysdata"
export NOTARY_PROFILE=${NOTARY_PROFILE:-sysdata}

cd "$root"

# Preconditions: main branch, clean tree, tooling present.
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || { echo "release from main, not $branch" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "notarytool profile '$NOTARY_PROFILE' not found; run notarytool store-credentials" >&2; exit 1; }

# Bump.
current=$(tr -d '[:space:]' < VERSION)
IFS=. read -r major minor patch <<< "$current"
case "$part" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac
version="$major.$minor.$patch"
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "tag $tag already exists" >&2; exit 1; }
echo "==> $current -> $version"

# Verify before anything is published.
swift build
swift test
shellcheck sysdata scripts/*.sh

printf '%s\n' "$version" > VERSION
scripts/build-app.sh
archive="build/SysDataMenu-$version.zip"
[ -f "$archive" ] || { echo "missing $archive" >&2; exit 1; }
spctl --assess --type execute "build/SysDataMenu.app"

# Release notes: commits since the previous tag.
previous=$(git describe --tags --abbrev=0 2>/dev/null || true)
log_range=()
[ -n "$previous" ] && log_range=("$previous..HEAD")
notes=$(mktemp)
{
  echo "## Changes"
  git log ${log_range[@]+"${log_range[@]}"} --no-merges --pretty='- %s' | grep -vE '^- (chore: release|docs: record)' || true
  echo
  echo "## Install"
  echo '```bash'
  echo "brew install --cask $tap_repo/$cask" | sed 's|/homebrew-tap/|/tap/|'
  echo '```'
  echo "or unzip \`SysDataMenu-$version.zip\` and move the app to /Applications. Signed and notarized. Requires macOS 14 or later."
} > "$notes"

# Commit, tag, push, publish.
git add VERSION
git commit -q -m "chore: release $tag"
git tag -a "$tag" -m "$tag"
git push -q origin main "$tag"
gh release create "$tag" "$archive" --repo "$repo" --title "$tag" --notes-file "$notes"
rm -f "$notes"

# Homebrew cask.
sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
tap_dir=$(mktemp -d)
gh repo clone "$tap_repo" "$tap_dir" -- -q
sed -i '' \
  -e "s/version \"[0-9.]*\"/version \"$version\"/" \
  -e "s/sha256 \"[0-9a-f]*\"/sha256 \"$sha\"/" \
  "$tap_dir/Casks/$cask.rb"
ruby -c "$tap_dir/Casks/$cask.rb" >/dev/null
git -C "$tap_dir" commit -qam "$cask $version"
git -C "$tap_dir" push -q origin main
rm -rf "$tap_dir"

echo "==> released $tag: https://github.com/$repo/releases/tag/$tag"
