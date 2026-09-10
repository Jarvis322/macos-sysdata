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

# The changelog is written before the release, not derived from it: a list of
# commit subjects says what was touched, not what changed for anyone using
# this. Its section becomes the release notes.
grep -q "^## $tag " CHANGELOG.md || {
  echo "CHANGELOG.md has no '## $tag' section; write it before releasing" >&2
  exit 1
}
echo "==> $current -> $version"

# Verify before anything is published.
# The same checks CI would run, plus the disk-walking tests: a release is the
# one moment those have to happen.
SYSDATA_SCAN_TESTS=1 scripts/ci.sh

printf '%s\n' "$version" > VERSION
scripts/build-app.sh
scripts/make-dmg.sh
archive="build/SysDataMenu-$version.zip"
image="build/SysDataMenu-$version.dmg"
for artefact in "$archive" "$image"; do
  [ -f "$artefact" ] || { echo "missing $artefact" >&2; exit 1; }
done
spctl --assess --type execute "build/SysDataMenu.app"

# Release notes: this version's section of the changelog, unwrapped, because
# GitHub turns each newline in a release body into a visible line break.
notes=$(mktemp)
{
  awk -v tag="## $tag " '
    index($0, tag) == 1 { inside = 1; next }
    inside && /^## v/ { exit }
    inside { print }
  ' CHANGELOG.md | awk -f scripts/unwrap-markdown.awk
  echo
  echo "## Install"
  echo '```bash'
  echo "brew install --cask $tap_repo/$cask" | sed 's|/homebrew-tap/|/tap/|'
  echo '```'
  echo "or open \`SysDataMenu-$version.dmg\` and drag the app to Applications. The zip is the same app for anyone scripting the download. Signed and notarized. Requires macOS 14 or later."
} > "$notes"

# Commit, tag, push, publish.
git add VERSION
git commit -q -m "chore: release $tag"
git tag -a "$tag" -m "$tag"
git push -q origin main "$tag"
gh release create "$tag" "$image" "$archive" --repo "$repo" --title "$tag" --notes-file "$notes"
rm -f "$notes"

# Homebrew cask.
sha=$(shasum -a 256 "$image" | cut -d' ' -f1)
tap_dir=$(mktemp -d)
gh repo clone "$tap_repo" "$tap_dir" -- -q
sed -i '' \
  -e "s/version \"[0-9.]*\"/version \"$version\"/" \
  -e "s/sha256 \"[0-9a-f]*\"/sha256 \"$sha\"/" \
  -e 's/SysDataMenu-#{version}\.zip/SysDataMenu-#{version}.dmg/' \
  "$tap_dir/Casks/$cask.rb"
# The checksum is the image's, so the cask must be pointing at the image.
grep -q 'SysDataMenu-#{version}.dmg' "$tap_dir/Casks/$cask.rb" \
  || { echo "cask still points at the zip; its sha256 would not match" >&2; exit 1; }
ruby -c "$tap_dir/Casks/$cask.rb" >/dev/null
git -C "$tap_dir" commit -qam "$cask $version"
git -C "$tap_dir" push -q origin main
rm -rf "$tap_dir"

echo "==> released $tag: https://github.com/$repo/releases/tag/$tag"
