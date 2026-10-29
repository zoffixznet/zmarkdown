#!/usr/bin/env bash
# Install everything needed to build and run ZMarkdown on a Debian/Ubuntu-family
# system (Kubuntu 24.04 KDE on X11 or Wayland, and Kali XFCE all qualify).
#
# Installs the GTK3 and WebKitGTK 4.1 development packages, a dialog helper
# (zenity as a portable fallback; KDE already ships kdialog), and xvfb for the
# headless test, then installs Nim via choosenim if no Nim is present. The Nim
# libraries the app uses are vendored in the repository, so nimble is not needed
# and nothing is fetched from a package registry. Uses sudo for the system
# packages only.
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
# Fixed order so the output is stable run to run. The regex library the
# markdown renderer uses (PCRE) is vendored and statically linked by the build,
# so it is deliberately not in this list; modern distros no longer package it.
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
#
# choosenim installs into ~/.nimble/bin, so put that on PATH before looking for
# nim: a shell that could not see an existing installation is what made earlier
# versions of this script install Nim again.
export PATH="$HOME/.nimble/bin:$PATH"

if command -v nim >/dev/null 2>&1; then
  # Whatever Nim is there is left alone; this script never upgrades or
  # reinstalls an existing one.
  echo "==> Nim already installed, leaving it alone: $(nim --version | head -1)"
elif [ -x "$HOME/.nimble/bin/choosenim" ]; then
  # choosenim is present but no toolchain is selected. Ask it for one directly
  # rather than re-running the bootstrapper, which downloads choosenim again and
  # can leave a second toolchain next to the first.
  echo "==> choosenim is installed but no Nim is selected; installing stable Nim"
  CHOOSENIM_NO_ANALYTICS=1 choosenim stable -y
else
  echo "==> Installing Nim via choosenim"
  export CHOOSENIM_NO_ANALYTICS=1
  curl -sSf https://nim-lang.org/choosenim/init.sh | sh -s -- -y
fi

# Make ~/.nimble/bin visible to future shells. Login shells read ~/.profile, but
# terminal emulators usually start non-login shells, which read ~/.bashrc and not
# ~/.profile, so the line goes into both. A shell where nim is not found is what
# made earlier versions of this script reinstall it.
if [ -d "$HOME/.nimble/bin" ]; then
  path_line='export PATH="$HOME/.nimble/bin:$PATH"'
  if ! grep -q '.nimble/bin' "$HOME/.profile" 2>/dev/null; then
    echo "$path_line" >> "$HOME/.profile"
  fi
  if [ -f "$HOME/.bashrc" ] && ! grep -q '.nimble/bin' "$HOME/.bashrc"; then
    echo "$path_line" >> "$HOME/.bashrc"
  fi
fi

# Report, without removing anything, the copies of Nim that installers leave
# behind; 'make nim-cleanup' removes them.
bash "$(dirname "$0")/nim-cleanup.sh" --list

echo "==> Done. Nim: $(nim --version | head -1)"
echo "    You can now run: make build && make run"
