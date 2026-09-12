#!/bin/bash
# Regenerates docs/llms.txt and docs/llms-full.txt from README.md and VERSION.
#
# llmstxt.org asks a site for two plain files: a short index, and the whole
# thing as text. The README is already the whole thing, so keeping a second
# hand-written copy of it only guarantees the two drift. This turns one into
# the other.
#
#   scripts/make-llms.sh          # write the files
#   scripts/make-llms.sh --check  # fail if they are out of date (ci.sh)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

site="https://macos-sysdata.yigitech.dev"
blob="https://github.com/Jarvis322/macos-sysdata/blob/main"
version=$(tr -d '[:space:]' < VERSION)

summary="A free Mac app that opens macOS \"System Data\" — the largest, least explained line in Storage settings — and lets you delete what is inside it, item by item, with every command shown before it runs. Menu bar or window, macOS 14 or later, no account and no analytics."

index_file() {
  cat <<EOF
# System Data Unpacked

> $summary

System Data is what macOS calls everything Storage settings cannot file under Apps, Photos or Documents: simulator runtimes, Xcode caches, package-manager stores, virtual machine disks, local Time Machine snapshots, logs, per-app data folders. macOS shows the total and nothing else. This app measures each item on disk, labels it Safe, Review or Manual, and deletes only what you tick.

Current version: $version. Install: \`brew install --cask Jarvis322/tap/sysdata\`

## Pages

- [Home]($site/): what the app does, what it finds, and what System Data actually is
- [Full text]($site/llms-full.txt): the README in full, for a model that needs the detail

## Source and releases

- [Repository](https://github.com/Jarvis322/macos-sysdata): Swift 6 and SwiftUI, published so the delete commands can be read
- [Latest release](https://github.com/Jarvis322/macos-sysdata/releases/latest): signed and notarized disk image, universal binary
- [Changelog]($blob/CHANGELOG.md): every release, including two that shipped a broken updater and what to do about them
- [Purgeable space measurement]($blob/docs/purgeable-measurement.md): why the purgeable figure is an estimate and not space you can plan around

## Author

- [yigitech](https://yigitech.dev): Yigit Can Polat, iOS, macOS and web developer
- [X](https://x.com/yigitech)
- [GitHub](https://github.com/Jarvis322)
EOF
}

full_file() {
  cat <<EOF
# System Data Unpacked

> $summary

Site: $site/
Source: https://github.com/Jarvis322/macos-sysdata
Version: $version
Author: Yigit Can Polat (https://yigitech.dev, https://x.com/yigitech, https://github.com/Jarvis322)

Everything below is the project's README, the same text the repository carries.

EOF

  # The README opens with an HTML banner (icon, badges, screenshot) that says
  # nothing in plain text; the prose starts after the rule that closes it.
  awk 'seen { print } /^---$/ && !seen { seen = 1 }' README.md |
    # Repository-relative links mean nothing once the file is served from the
    # site, and in-page anchors mean nothing in a text file.
    sed -E \
      -e "s#\]\((CHANGELOG\.md|CONTRIBUTING\.md|LICENSE|docs/[^)]+|Sources/[^)]+|scripts/[^)]+)\)#]($blob/\1)#g" \
      -e 's|\[([^][]+)\]\(#[^)]*\)|\1|g'
}

write_or_check() {
  local path=$1 content=$2
  if [ "${check:-}" = "1" ]; then
    printf '%s' "$content" | cmp -s - "$path" \
      || { echo "$path is out of date; run scripts/make-llms.sh" >&2; exit 1; }
  else
    printf '%s' "$content" > "$path"
    echo "wrote $path"
  fi
}

case "${1:-}" in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 1 ;;
esac

write_or_check docs/llms.txt "$(index_file)"$'\n'
write_or_check docs/llms-full.txt "$(full_file)"$'\n'
