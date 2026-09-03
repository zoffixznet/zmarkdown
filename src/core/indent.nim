## What one press of Tab puts into the document, and what one press of Shift+Tab
## takes back out.
##
## Two separate things decide it. The preference is a setting and lives in the
## state file: tabs, spaces, or "whatever the document already uses". The width
## is how many spaces one level is - the number Tab inserts in space mode, and
## the number Shift+Tab is willing to strip in either mode, so a file indented
## with spaces still comes out one level at a time even when the preference says
## tabs.
##
## "Whatever the document already uses" is the default, because a document
## usually knows: editing somebody's spaces-indented file should not sprinkle
## tabs through it, and editing a tab-indented one should not do the reverse.
##
## Pure text and arithmetic - no GUI, no disk - so all of it is unit-tested on
## its own.

import std/options
import std/strutils

type
  IndentPref* = enum
    ## What the user asked for in Settings.
    ipAuto = "auto"     ## follow whatever the open document already uses
    ipTab = "tab"       ## always a tab
    ipSpace = "space"   ## always spaces

  IndentKind* = enum
    ## What is actually being inserted right now, once the preference and the
    ## document have both had their say. This is what the toolbar toggle shows,
    ## and what the toggle switches between for the document in front of you.
    ikTab = "tab"
    ikSpace = "space"

const
  DefaultIndentPref* = ipAuto
  DefaultTabWidth* = 4
  MinTabWidth* = 1
    ## One space is a strange thing to indent with, but it is a width, and
    ## refusing it would be the app arguing with the user about their own file.
  MaxTabWidth* = 16
    ## Past this the "indentation" is wider than most of the text on the line;
    ## the cap is there so a typo in the box cannot make the editor unusable.

func parseIndentPref*(s: string): Option[IndentPref] =
  ## A preference read back from its persisted name, or `none` for anything that
  ## is not one - a hand-edited state file, a value from some later version.
  case s
  of "auto": some(ipAuto)
  of "tab": some(ipTab)
  of "space": some(ipSpace)
  else: none(IndentPref)

func parseIndentKind*(s: string): Option[IndentKind] =
  ## The same, for the style in force on one document. "auto" is deliberately
  ## not accepted: by the time something is being inserted, the question has
  ## been settled.
  case s
  of "tab": some(ikTab)
  of "space": some(ikSpace)
  else: none(IndentKind)

func clampTabWidth*(n: int): int =
  ## Hold a width inside the range that makes sense, so a saved zero or a
  ## hand-edited hundred cannot produce indentation nobody can work with.
  if n < MinTabWidth: MinTabWidth
  elif n > MaxTabWidth: MaxTabWidth
  else: n

func indentUnit*(kind: IndentKind, width: int): string =
  ## The exact string one press of Tab puts in.
  case kind
  of ikTab: "\t"
  of ikSpace: spaces(clampTabWidth(width))

func detectIndent*(text: string): Option[IndentKind] =
  ## What the document itself indents with.
  ##
  ## A tab at the front of any line settles it as tabs: one tab in the file is
  ## proof enough that tabs are what it uses, and matching it is the whole point.
  ## Failing that, a line beginning with two or more spaces says spaces - two,
  ## because a single leading space is a typo far more often than it is
  ## indentation. A document with no indented line at all says nothing, and the
  ## caller decides.
  var sawSpaces = false
  var i = 0
  while i < text.len:
    # `i` is at the start of a line here, every time round. Take the whole run
    # of leading whitespace in one go, whatever it is made of.
    var j = i
    var spaces = 0
    var tabbed = false
    while j < text.len and text[j] in {' ', '\t'}:
      if text[j] == '\t': tabbed = true
      else: inc spaces
      inc j
    # A line of nothing but whitespace indents nothing: it is a blank line, and
    # the stray tab or two files collect on one must not decide this for the
    # whole document.
    if j < text.len and text[j] notin {'\r', '\n'}:
      if tabbed: return some(ikTab)  # a tab, with or without spaces before it
      if spaces >= 2: sawSpaces = true
    i = j
    while i < text.len and text[i] != '\n': inc i
    if i < text.len: inc i
  if sawSpaces: some(ikSpace) else: none(IndentKind)

func resolveIndent*(pref: IndentPref, text: string): IndentKind =
  ## The style to use for a document: what the user asked for, or - when they
  ## asked for whatever the document uses - what the document turns out to use.
  ## A document that gives no clue at all gets a tab, which is what the key
  ## itself means and what this editor did before any of it was configurable.
  case pref
  of ipTab: ikTab
  of ipSpace: ikSpace
  of ipAuto:
    let seen = detectIndent(text)
    if seen.isSome: seen.get else: ikTab
