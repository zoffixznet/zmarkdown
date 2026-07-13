# Build configuration for ZMarkdown.
#
# The webview binding is header-only C++, so the whole app builds with the C++
# backend. ORC is the memory manager the binding's examples use, and threads are
# enabled because a bound callback may run off the main loop.

--backend:cpp
--mm:orc
--threads:on

# Point Nim at the vendored webview binding so `import webview` resolves to our
# patched copy rather than any nimble-installed one.
switch("path", "src/vendor/webview")

# Tell the vendored binding to take the Linux/GTK path explicitly. On Windows the
# binding auto-selects the Edge WebView2 backend.
when defined(linux):
  --define:webviewGtk

when defined(release):
  --opt:size
  --passC:"-DNDEBUG"

# The self-test and normal runs both benefit from readable stack traces during
# development; release builds drop them for size.
when not defined(release):
  --stackTrace:on
  --lineTrace:on
