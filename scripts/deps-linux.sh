#!/usr/bin/env bash
# Install everything needed to build and run ZMarkdown on a Debian/Ubuntu-family
# system (Kubuntu 24.04 KDE on X11 or Wayland, and Kali XFCE all qualify).
#
# Installs the GTK3 and WebKitGTK 4.1 development packages, a dialog helper
# (zenity as a portable fallback; KDE already ships kdialog), and xvfb for the
# headless test, then installs Nim via choosenim if it is missing, then the
# pinned nimble dependencies. Uses sudo for the system packages.
set -euo pipefail

# Single source of truth for the system packages, kept next to the descriptions
# printed below so the two never drift.
SYSTEM_PKGS=(
  build-essential
  pkg-config
  libgtk-3-dev
  libwebkit2gtk-4.1-dev
  zenity
  xvfb
  ca-certificates
  curl
)

echo "==> System packages to install with sudo (apt):"
echo "      build-essential         C/C++ toolchain (Nim compiles through a C++ backend)"
echo "      pkg-config              finds the GTK and WebKit build and link flags"
echo "      libgtk-3-dev            GTK 3, the toolkit the Linux webview is built on"
echo "      libwebkit2gtk-4.1-dev   WebKitGTK 4.1, renders the markdown preview"
echo "      zenity                  native file dialog fallback (KDE already ships kdialog)"
echo "      xvfb                    virtual display, used only by 'make test'"
echo "      ca-certificates, curl   fetch the Nim toolchain over HTTPS"
echo
echo "    Commands that will run as root:"
echo "      sudo apt-get update"
echo "      sudo apt-get install -y --no-install-recommends ${SYSTEM_PKGS[*]}"
echo
echo "    Nim and the Nim libraries install per-user under ~/.nimble (no sudo)."
echo "    You will be asked for your password now. Press Ctrl-C to cancel."
echo

sudo apt-get update
sudo apt-get install -y --no-install-recommends "${SYSTEM_PKGS[@]}"

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
