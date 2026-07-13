#!/usr/bin/env bash
# Generate the ZMarkdown PNG icons and the Windows .ico from the SVG source.
#
# Renders src/ui/assets/icon.svg to PNGs at 16/32/48/64/128/256 and bundles the
# small sizes into icon.ico. Prefers rsvg-convert, then Inkscape, then
# ImageMagick, whichever is installed. Outputs are not committed; the SVG source
# and this script are.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg="$here/src/ui/assets/icon.svg"
out="$here/src/ui/assets"
sizes=(16 32 48 64 128 256)

if [[ ! -f "$svg" ]]; then
  echo "icon source not found: $svg" >&2
  exit 1
fi

render() { # render <size> <outfile>
  local size="$1" file="$2"
  if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w "$size" -h "$size" "$svg" -o "$file"
  elif command -v inkscape >/dev/null 2>&1; then
    inkscape "$svg" --export-type=png -w "$size" -h "$size" -o "$file" >/dev/null 2>&1
  elif command -v convert >/dev/null 2>&1; then
    convert -background none -density 384 "$svg" -resize "${size}x${size}" "$file"
  elif command -v magick >/dev/null 2>&1; then
    magick -background none -density 384 "$svg" -resize "${size}x${size}" "$file"
  else
    echo "no SVG rasterizer found (need rsvg-convert, inkscape, or ImageMagick)" >&2
    exit 1
  fi
}

echo "Rendering PNG sizes..."
for s in "${sizes[@]}"; do
  render "$s" "$out/icon-${s}.png"
  echo "  icon-${s}.png"
done

echo "Building icon.ico..."
ico_inputs=("$out/icon-16.png" "$out/icon-32.png" "$out/icon-48.png" "$out/icon-64.png" "$out/icon-128.png" "$out/icon-256.png")
if command -v convert >/dev/null 2>&1; then
  convert "${ico_inputs[@]}" "$out/icon.ico"
elif command -v magick >/dev/null 2>&1; then
  magick "${ico_inputs[@]}" "$out/icon.ico"
else
  echo "cannot build .ico without ImageMagick; PNGs are still generated" >&2
fi

echo "Done. Icons in $out"
