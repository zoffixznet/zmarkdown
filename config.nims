# Build configuration for ZMarkdown.
#
# The webview binding is header-only C++, so the whole app builds with the C++
# backend. ORC is the memory manager the binding's examples use, and threads are
# enabled because a bound callback may run off the main loop.

--backend:cpp
--mm:orc
--threads:on

# Keep the C/C++ build cache in the project (one subdir per target) so
# `make clean`, which removes nimcache/, reliably forces a full recompile,
# including the vendored webview.cc when its header changes. Nim otherwise caches
# under ~/.cache/nim, where `make clean` cannot reach it.
switch("nimcache", "nimcache/" & projectName())

# Point Nim at the vendored webview binding so `import webview` resolves to our
# patched copy rather than any nimble-installed one.
switch("path", "src/vendor/webview")

# The markdown renderer uses Nim's std/re, a wrapper around the legacy PCRE1
# library. PCRE1 is end-of-life and modern distros no longer package it, so the
# vendored PCRE 8.45 source (src/vendor/pcre) is built into a static library by
# scripts/build-pcre.sh (make runs it automatically). When it is present, link
# it in; the binary then needs no PCRE at runtime, on Linux or Windows.
let staticPcre = thisDir() & "/build/pcre/libpcre.a"
if fileExists(staticPcre):
  switch("dynlibOverride", "pcre")
  switch("passL", staticPcre)
else:
  echo "warning: build/pcre/libpcre.a not found; the binary will try to load"
  echo "         the system PCRE at runtime, which modern distros no longer"
  echo "         ship. Run 'bash scripts/build-pcre.sh' to link it statically."

# Tell the vendored binding to take the Linux/GTK path explicitly. On Windows the
# binding auto-selects the Edge WebView2 backend.
when defined(linux):
  --define:webviewGtk

when defined(windows):
  # Build a GUI executable so no console window appears (WebView2 is preinstalled
  # on Windows 11). Embed the app icon: the CI build compiles the .rc into a
  # .res next to the icon and passes ZMARKDOWN_RES=path so it is linked in.
  --app:gui
  let resFile = getEnv("ZMARKDOWN_RES")
  if resFile.len > 0:
    switch("passL", resFile)

when defined(release):
  --opt:size
  --passC:"-DNDEBUG"

# The self-test and normal runs both benefit from readable stack traces during
# development; release builds drop them for size.
when not defined(release):
  --stackTrace:on
  --lineTrace:on
