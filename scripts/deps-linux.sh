#!/usr/bin/env bash
# Install everything needed to build and run ZMarkdown on a Debian/Ubuntu-family
# system (Kubuntu 24.04 KDE on X11 or Wayland, and Kali XFCE all qualify).
#
# Installs the GTK3 and WebKitGTK 4.1 development packages, a dialog helper
# (zenity as a portable fallback; KDE already ships kdialog), and xvfb for the
# headless test, then installs Nim via choosenim if it is missing, then the
# pinned nimble dependencies. Uses sudo for the system packages.
set -euo pipefail

echo "==> Installing system packages (needs sudo)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential \
  pkg-config \
  libgtk-3-dev \
  libwebkit2gtk-4.1-dev \
  zenity \
  xvfb \
  ca-certificates curl

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
