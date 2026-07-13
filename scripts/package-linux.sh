#!/usr/bin/env bash
# Package the Linux build as a tarball: the binary, the README, the .desktop
# file, and the icons. The tarball is what CI attaches to a GitHub Release; it is
# not committed to the repo.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$here/build/zmarkdown"
version="$(grep -oP '^version\s*=\s*"\K[^"]+' "$here/zmarkdown.nimble" | head -1)"
[[ -z "$version" ]] && version="0.0.0"

name="zmarkdown-${version}-linux-x86_64"
stage="$here/dist/$name"

if [[ ! -x "$bin" ]]; then
  echo "package: binary not found at $bin (run 'make build' first)" >&2
  exit 1
fi

echo "==> Staging $name"
rm -rf "$stage"
mkdir -p "$stage/icons"

cp "$bin" "$stage/zmarkdown"
cp "$here/README.md" "$stage/README.md"
cp "$here/packaging/zmarkdown.desktop" "$stage/zmarkdown.desktop"

# Icons: ship the PNG set and the SVG source.
cp "$here/src/ui/assets/icon.svg" "$stage/icons/zmarkdown.svg"
for s in 16 32 48 64 128 256; do
  [[ -f "$here/src/ui/assets/icon-${s}.png" ]] && cp "$here/src/ui/assets/icon-${s}.png" "$stage/icons/zmarkdown-${s}.png"
done

# A tiny install helper for the user.
cat > "$stage/install.sh" <<'EOF'
#!/usr/bin/env bash
# Install ZMarkdown into your home directory (no root needed).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix="${PREFIX:-$HOME/.local}"
install -Dm755 "$here/zmarkdown" "$prefix/bin/zmarkdown"
install -Dm644 "$here/zmarkdown.desktop" "$prefix/share/applications/zmarkdown.desktop"
for s in 16 32 48 64 128 256; do
  [ -f "$here/icons/zmarkdown-${s}.png" ] && \
    install -Dm644 "$here/icons/zmarkdown-${s}.png" \
    "$prefix/share/icons/hicolor/${s}x${s}/apps/zmarkdown.png"
done
install -Dm644 "$here/icons/zmarkdown.svg" "$prefix/share/icons/hicolor/scalable/apps/zmarkdown.svg"
echo "Installed to $prefix. Ensure $prefix/bin is on your PATH."
EOF
chmod +x "$stage/install.sh"

echo "==> Creating tarball"
mkdir -p "$here/dist"
tar -C "$here/dist" -czf "$here/dist/${name}.tar.gz" "$name"
echo "Wrote dist/${name}.tar.gz"
