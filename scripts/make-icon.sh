#!/bin/bash
# Renders the app icon and packs it into assets/AppIcon.icns plus a PNG for
# the README. Requires only the tools that ship with macOS.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
assets="$root/assets"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$assets"
swift "$root/scripts/make-icon.swift" "$work/icon-1024.png"

iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$assets/AppIcon.icns"
sips -z 512 512 "$work/icon-1024.png" --out "$assets/icon.png" >/dev/null
echo "wrote $assets/AppIcon.icns and $assets/icon.png"
