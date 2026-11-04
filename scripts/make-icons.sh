#!/usr/bin/env bash
# Renders every icon this project ships from the two SVG masters beside them.
#
# The detailed drawing carries the circuit traces and is used from 64 px up,
# where they survive. At 16 and 32 px they collapse into a smudge, so those
# sizes come from the simplified drawing: the same hexagon and brain, no traces.
#
# Writes src-tauri/icons/* (the app icon set) and priv/static/favicon.ico.
# Two runs with the same tools write the same bytes, so a run that changes
# nothing leaves the working tree alone. A different ImageMagick build (this
# machine has two, arm64 and x86_64) re-encodes the same pixels to other bytes;
# the pictures are the same, and only then does a rerun show up in git.
set -euo pipefail

cd "$(dirname "$0")/.."
icons=src-tauri/icons
detailed=grid-brain-vector
simplified=grid-brain-vector-simplified

for tool in rsvg-convert magick iconutil; do
  command -v "$tool" >/dev/null ||
    { echo "make-icons.sh needs $tool on PATH" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/ex-tbp-monty-icons.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1024 px master: square canvas, artwork trimmed and centred, alpha preserved.
# -strip matters: without it the PNG carries a creation timestamp and two runs
# of this script produce two different files for the same picture.
render() {
  rsvg-convert -w 1024 -h 1024 "$icons/$1.svg" -o "$work/$1-raw.png"
  magick "$work/$1-raw.png" -trim +repage -resize 900x900 \
    -background none -gravity center -extent 1024x1024 -strip \
    -define png:color-type=6 "PNG32:$work/$1.png"
}

render "$detailed"
render "$simplified"

# Every frame is written as 32-bit RGBA on purpose. Without the explicit format
# the encoder hands the .ico writer a quantized palette, and a hexagon outline
# two pixels wide turns into a banded smear.
frame() {
  local master=$1 size=$2 out=$3
  magick "$work/$master.png" -filter Lanczos -resize "${size}x${size}" -strip \
    -define png:color-type=6 "PNG32:$out"
}

# The PNGs the bundle lists; 32 px is what Finder lists and a status item uses.
frame "$detailed" 1024 "$icons/icon.png"
frame "$detailed" 128 "$icons/128x128.png"
frame "$detailed" 256 "$icons/128x128@2x.png"
frame "$simplified" 32 "$icons/32x32.png"

# An .iconset is the ten names iconutil expects, nothing else, and the small
# sizes come from the drawing that reads at them.
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
frame "$simplified" 16 "$iconset/icon_16x16.png"
frame "$simplified" 32 "$iconset/icon_16x16@2x.png"
frame "$simplified" 32 "$iconset/icon_32x32.png"
frame "$detailed" 64 "$iconset/icon_32x32@2x.png"
frame "$detailed" 128 "$iconset/icon_128x128.png"
frame "$detailed" 256 "$iconset/icon_128x128@2x.png"
frame "$detailed" 256 "$iconset/icon_256x256.png"
frame "$detailed" 512 "$iconset/icon_256x256@2x.png"
frame "$detailed" 512 "$iconset/icon_512x512.png"
frame "$detailed" 1024 "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$icons/icon.icns"

# One .ico holds several sizes, each again from the drawing that reads at it.
for size in 16 32 48; do
  frame "$simplified" "$size" "$work/ico-$size.png"
done
frame "$detailed" 256 "$work/ico-256.png"
magick "$work/ico-16.png" "$work/ico-32.png" "$work/ico-48.png" "$work/ico-256.png" \
  "$icons/icon.ico"

# The browser tab is small everywhere, so it leans on the simple art too, with
# one larger frame for the tab preview in a crowded window.
for size in 16 32 48; do
  frame "$simplified" "$size" "$work/fav-$size.png"
done
frame "$detailed" 64 "$work/fav-64.png"
mkdir -p priv/static
magick "$work/fav-16.png" "$work/fav-32.png" "$work/fav-48.png" "$work/fav-64.png" \
  priv/static/favicon.ico

echo "wrote $icons and priv/static/favicon.ico"
