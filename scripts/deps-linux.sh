#!/usr/bin/env bash
# Install everything needed to build and run ZMarkdown on a Debian/Ubuntu-family
# system (Kubuntu 24.04 KDE on X11 or Wayland, and Kali XFCE all qualify).
#
# Installs the GTK3 and WebKitGTK 4.1 development packages, a dialog helper
# (zenity as a portable fallback; KDE already ships kdialog), and xvfb for the
# headless test, then installs Nim via choosenim if it is missing, then the
# pinned nimble dependencies. Uses sudo for the system packages.
set -euo pipefail

# System packages ZMarkdown needs, each with a one-line reason. This is the
# single source of truth; nothing below hardcodes the list again.
declare -A PKG_DESC=(
  [build-essential]="C/C++ toolchain (Nim compiles through a C++ backend)"
  [pkg-config]="finds the GTK and WebKit build and link flags"
  [libgtk-3-dev]="GTK 3, the toolkit the Linux webview is built on"
  [libwebkit2gtk-4.1-dev]="WebKitGTK 4.1, renders the markdown preview"
  [zenity]="native file dialog fallback (KDE already ships kdialog)"
  [xvfb]="virtual display, used only by 'make test'"
  [ca-certificates]="trusted CA roots for the HTTPS downloads below"
  [curl]="fetches the Nim toolchain over HTTPS"
)
# Fixed order so the output is stable run to run.
SYSTEM_PKGS=(build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev zenity xvfb ca-certificates curl)

# Only elevate for what is actually missing. dpkg-query tells us what is already
# installed, so an already-set-up system never gets a sudo prompt at all.
present=()
missing=()
for pkg in "${SYSTEM_PKGS[@]}"; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
    present+=("$pkg")
  else
    missing+=("$pkg")
  fi
done

if [ "${#present[@]}" -gt 0 ]; then
  echo "==> Already installed, skipping: ${present[*]}"
fi

if [ "${#missing[@]}" -eq 0 ]; then
  echo "==> All required system packages are already present. No sudo needed."
else
  echo
  echo "==> Need to install these with sudo (apt):"
  for pkg in "${missing[@]}"; do
    printf '      %-24s %s\n' "$pkg" "${PKG_DESC[$pkg]}"
  done
  echo
  echo "    Commands that will run as root:"
  echo "      sudo apt-get update"
  echo "      sudo apt-get install -y --no-install-recommends ${missing[*]}"
  echo
  echo "    You will be asked for your password now. Press Ctrl-C to cancel."
  echo
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${missing[@]}"
fi

# Nim via choosenim (per-user, no sudo). The distro nim package is often too old.
if ! command -v nim >/dev/null 2>&1; then
  echo "==> Installing Nim via choosenim"
  export CHOOSENIM_NO_ANALYTICS=1
  curl -sSf https://nim-lang.org/choosenim/init.sh | sh -s -- -y
  # choosenim installs into ~/.nimble/bin
  export PATH="$HOME/.nimble/bin:$PATH"
  if ! grep -q '.nimble/bin' "$HOME/.profile" 2>/dev/null; then
    echo 'export PATH="$HOME/.nimble/bin:$PATH"' >> "$HOME/.profile"
  fi
else
  echo "==> Nim already installed: $(nim --version | head -1)"
fi

export PATH="$HOME/.nimble/bin:$PATH"

echo "==> Installing pinned nimble dependencies"
# The webview binding is vendored in the repo, so only these registry packages
# are fetched. Versions are pinned to match the .nimble requirements.
nimble install -y "markdown@0.8.8"
nimble install -y "tinyfiledialogs@3.21.3"

echo "==> Done. Nim: $(nim --version | head -1)"
echo "    You can now run: make build && make run"
