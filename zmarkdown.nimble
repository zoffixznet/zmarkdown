# Package

version       = "1.7.0"
author        = "Zoffix Znet"
description    = "A small, fast desktop markdown editor and viewer"
license        = "MIT"
srcDir        = "src"
bin            = @["zmarkdown"]
binDir        = "build"

# Dependencies
#
# Every library the app uses is vendored under src/vendor: the webview binding
# (src/vendor/webview), nim-markdown (src/vendor/markdown), tinyfiledialogs
# (src/vendor/tinyfiledialogs) and PCRE (src/vendor/pcre). Nothing is fetched from
# the package registry, so the only requirement is the compiler itself.

requires "nim >= 2.0.0"

# Tasks

task test, "Run the unit test suite":
  exec "nim c -r --hints:off tests/test_editing.nim"
  exec "nim c -r --hints:off tests/test_state.nim"
  exec "nim c -r --hints:off tests/test_files.nim"
  exec "nim c -r --hints:off tests/test_history.nim"
  exec "nim c -r --hints:off tests/test_search.nim"
  exec "nim c -r --hints:off tests/test_images.nim"
  exec "nim c -r --hints:off tests/test_dialogs.nim"
  exec "nim c -r --hints:off tests/test_nav.nim"
  exec "nim c -r --hints:off tests/test_recent.nim"
  exec "nim c -r --hints:off tests/test_indent.nim"
  exec "nim c -r --hints:off tests/test_cli.nim"
  exec "nim cpp -r --hints:off tests/test_markdown.nim"
