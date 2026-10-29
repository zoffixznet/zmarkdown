# This file exists so that Nim treats this directory as its own package. Warnings
# raised inside a third-party library are then reported the way they are for any
# installed dependency, rather than shown as if they came from the application's
# own code. Nothing reads the fields below; nimble is not used to build ZMarkdown.
#
# The copy is nim-markdown 0.8.8 from https://github.com/soasme/nim-markdown with
# one local change: markdownpkg/entities.nim no longer depends on the standard
# library's deprecated htmlparser module (see the comment at the top of that
# file). The license is in LICENSE next to this file.

version       = "0.8.8"
author        = "Ju Lin"
description   = "A Markdown Parser in Nim World."
license       = "MIT"
