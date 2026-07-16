#!/usr/bin/env bash
# Build the vendored PCRE 8.45 into a static library, build/pcre/libpcre.a.
#
# Nim's std/re (which the markdown renderer uses) wraps the legacy PCRE1 C
# library. PCRE1 is end-of-life upstream and modern distros no longer package
# it (only PCRE2 ships), so instead of loading it at runtime the app links this
# static build; the finished binary then needs no PCRE anywhere, on any distro
# or on Windows. config.nims picks the library up automatically when present.
#
# The pristine upstream source tarball (BSD licensed; notice reproduced in the
# README) is vendored at src/vendor/pcre/pcre-8.45.tar.gz and verified against
# its published SHA-256 before use. The build follows PCRE's own
# NON-AUTOTOOLS-BUILD instructions: plain compiler + ar, no configure, no
# cmake, so the same script works on Linux and under MinGW on Windows.
set -euo pipefail

cd "$(dirname "$0")/.."

TARBALL=src/vendor/pcre/pcre-8.45.tar.gz
SHA256=4e6ce03e0336e8b4a3d6c2b70b1c5e18590a5673a98186da90d4f33c23defc09
OUT=build/pcre/libpcre.a
SRCDIR=build/pcre/pcre-8.45

CC="${CC:-gcc}"
AR="${AR:-ar}"

if [ -f "$OUT" ] && [ "$OUT" -nt "$TARBALL" ]; then
  echo "==> $OUT is up to date"
  exit 0
fi

echo "==> Verifying $TARBALL"
echo "$SHA256  $TARBALL" | sha256sum -c - >/dev/null

echo "==> Extracting to $SRCDIR"
rm -rf "$SRCDIR"
mkdir -p build/pcre
tar xzf "$TARBALL" -C build/pcre

# Per NON-AUTOTOOLS-BUILD: use the shipped generic configuration, the shipped
# default character tables, and compile the 8-bit library's source files.
# SUPPORT_UTF/SUPPORT_UCP enable UTF-8 and \p{...} handling, matching how the
# distro packages were built. pcre_jit_compile.c must be compiled even though
# JIT is not enabled; it provides the required stub functions.
cp "$SRCDIR/config.h.generic" "$SRCDIR/config.h"
cp "$SRCDIR/pcre.h.generic" "$SRCDIR/pcre.h"
cp "$SRCDIR/pcre_chartables.c.dist" "$SRCDIR/pcre_chartables.c"

SOURCES=(
  pcre_byte_order pcre_chartables pcre_compile pcre_config pcre_dfa_exec
  pcre_exec pcre_fullinfo pcre_get pcre_globals pcre_jit_compile
  pcre_maketables pcre_newline pcre_ord2utf8 pcre_refcount pcre_string_utils
  pcre_study pcre_tables pcre_ucd pcre_valid_utf8 pcre_version pcre_xclass
)

echo "==> Compiling PCRE 8.45 (static, with UTF-8 support)"
objects=()
for name in "${SOURCES[@]}"; do
  "$CC" -c -O2 -I"$SRCDIR" -DHAVE_CONFIG_H -DSUPPORT_UTF -DSUPPORT_UCP \
    -DPCRE_STATIC "$SRCDIR/$name.c" -o "$SRCDIR/$name.o"
  objects+=("$SRCDIR/$name.o")
done

"$AR" rcs "$OUT" "${objects[@]}"
echo "==> Built $OUT"
