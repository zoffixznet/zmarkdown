# Package

version       = "1.0.2"
author        = "Zoffix Znet"
description    = "A small, fast desktop markdown editor and viewer"
license        = "MIT"
srcDir        = "src"
bin            = @["zmarkdown"]
binDir        = "build"

# Dependencies
#
# The webview binding is vendored under src/vendor/webview and PCRE is vendored
# under src/vendor/pcre, so neither is listed here. These are the registry
# packages, pinned.

requires "nim >= 2.0.0"
requires "markdown == 0.8.8"
requires "tinyfiledialogs == 3.21.3"

# Tasks

task test, "Run the unit test suite":
  exec "nim c -r --hints:off tests/test_editing.nim"
  exec "nim c -r --hints:off tests/test_state.nim"
  exec "nim c -r --hints:off tests/test_files.nim"
  exec "nim cpp -r --hints:off tests/test_markdown.nim"
