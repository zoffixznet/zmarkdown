#!/usr/bin/env bash
# Find and remove the dead copies of Nim that installers leave behind. Each one is
# well over a hundred megabytes, and none of them is needed to build or run
# ZMarkdown. Three kinds are looked for:
#
#   1. Toolchains under ~/.choosenim/toolchains other than the one in use.
#      choosenim keeps every version it has ever installed, so after an upgrade
#      the previous toolchain stays on disk until someone removes it. The one in
#      use is named in ~/.choosenim/current and is never touched.
#   2. Installer archives under ~/.choosenim/downloads. choosenim unpacks the
#      archive it downloaded and then leaves the archive where it is.
#   3. Copies of Nim under ~/.nimble/pkgs2/nim-<version>-<hash>/. Current nimble
#      versions install the compiler itself as a package whenever they build
#      another package, one copy per Nim version. ZMarkdown no longer uses nimble
#      (all of its Nim libraries are vendored), so it needs none of them.
#
# Usage:
#   nim-cleanup.sh            list what would be removed, then ask before removing
#   nim-cleanup.sh --list     list only, remove nothing
#   nim-cleanup.sh -y|--yes   remove without asking
#
# The exact paths are always printed before anything is removed.
set -euo pipefail

mode=ask
for arg in "$@"; do
  case "$arg" in
    --list) mode=list ;;
    -y|--yes) mode=yes ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--list | -y|--yes]"
      echo "  --list      list leftover copies of Nim and their sizes, remove nothing"
      echo "  -y, --yes   remove them without asking"
      echo "  (no flag)   list them, then ask before removing"
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

export PATH="$HOME/.nimble/bin:$PATH"
export CHOOSENIM_NO_ANALYTICS=1

choosenim_dir="$HOME/.choosenim"

# The toolchain in use. ~/.choosenim/current holds its path, for example
# /home/me/.choosenim/toolchains/nim-2.2.10; only the last component matters.
current_name=""
if [ -f "$choosenim_dir/current" ]; then
  current_name="$(basename "$(tr -d '[:space:]' < "$choosenim_dir/current")")"
fi

# Each candidate is "<kind>|<path>"; the kind decides how it is described and
# removed.
candidates=()

if [ -d "$choosenim_dir/toolchains" ]; then
  for dir in "$choosenim_dir/toolchains"/*/; do
    [ -d "$dir" ] || continue
    dir="${dir%/}"
    if [ -n "$current_name" ] && [ "$(basename "$dir")" = "$current_name" ]; then
      continue
    fi
    candidates+=("toolchain|$dir")
  done
fi

if [ -d "$choosenim_dir/downloads" ]; then
  for entry in "$choosenim_dir/downloads"/*; do
    [ -e "$entry" ] || continue
    candidates+=("download|$entry")
  done
fi

if [ -d "$HOME/.nimble/pkgs2" ]; then
  for dir in "$HOME/.nimble/pkgs2"/nim-*/; do
    [ -d "$dir" ] || continue
    candidates+=("nimble-copy|${dir%/}")
  done
fi

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No leftover copies of Nim found."
  exit 0
fi

describe() {
  case "$1" in
    toolchain)   echo "toolchain not in use" ;;
    download)    echo "installer archive" ;;
    nimble-copy) echo "nimble's own copy of Nim" ;;
  esac
}

echo "Leftover copies of Nim:"
total_kb=0
for item in "${candidates[@]}"; do
  kind="${item%%|*}"
  path="${item#*|}"
  size="$(du -sh "$path" 2>/dev/null | cut -f1)"
  kb="$(du -sk "$path" 2>/dev/null | cut -f1)"
  total_kb=$((total_kb + ${kb:-0}))
  printf '  %6s  %s  (%s)\n' "$size" "$path" "$(describe "$kind")"
done
if [ -n "$current_name" ]; then
  echo "The toolchain in use, $choosenim_dir/toolchains/$current_name, is left alone."
fi
echo "Total: $((total_kb / 1024)) MB"

case "$mode" in
  list)
    echo "Nothing removed (--list). Run 'make nim-cleanup' to remove them."
    exit 0 ;;
  ask)
    # With no terminal to answer from, an empty answer means no.
    read -r -p "Remove these? [y/N] " answer || answer=""
    case "$answer" in
      y|Y|yes|YES|Yes) ;;
      *) echo "Nothing removed."; exit 0 ;;
    esac ;;
  yes) ;;
esac

for item in "${candidates[@]}"; do
  kind="${item%%|*}"
  path="${item#*|}"
  echo "Removing $path"
  case "$kind" in
    toolchain)
      # Let choosenim forget the version as well as delete it, when it can; the
      # directory is named nim-<version>.
      version="$(basename "$path")"
      version="${version#nim-}"
      if command -v choosenim >/dev/null 2>&1; then
        if ! choosenim remove "$version"; then
          echo "  choosenim could not remove it; deleting the directory instead"
          rm -rf "$path"
        fi
      else
        rm -rf "$path"
      fi ;;
    *)
      rm -rf "$path" ;;
  esac
done
echo "Done."
