// This translation unit builds the vendored, patched webview.h (see the
// "ZMarkdown vendored change" markers there and docs/DECISIONS.md). Nim keys
// recompilation on this file's timestamp, not the header's, so a fresh checkout
// (which stamps this file) rebuilds it and picks up the header patches. If you
// edit webview.h without changing this file, run `make clean` before rebuilding.
#include "webview.h"
