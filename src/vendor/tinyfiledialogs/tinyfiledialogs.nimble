# This file exists so that Nim treats this directory as its own package. Warnings
# raised inside a third-party library are then reported the way they are for any
# installed dependency, rather than shown as if they came from the application's
# own code. Nothing reads the fields below; nimble is not used to build ZMarkdown.
#
# The copy is the tinyfiledialogs Nim wrapper 3.21.3 from
# https://github.com/juancarlospaco/nim-tinyfiledialogs, unchanged, together with
# the tinyfiledialogs 3.21.3 C library (tinyfiledialogs.c and tinyfiledialogs.h)
# by Guillaume Vareille that it bundles and compiles in. Both licenses are in
# LICENSE next to this file.

version       = "3.21.3"
author        = "Juan Carlos"
description   = "TinyFileDialogs for Nim."
license       = "MIT"
