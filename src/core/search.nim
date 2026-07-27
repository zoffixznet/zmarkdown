## Find and replace over the raw markdown text.
##
## Pure text logic: no GUI, no side effects, unit-tested in isolation.
##
## Offsets crossing this module's boundary are UTF-16 code unit offsets, because
## that is what a browser textarea's `selectionStart` / `selectionEnd` report and
## what `setSelectionRange` expects. Nim strings are UTF-8 bytes, so the two do
## not agree the moment the document contains anything outside ASCII: "é" is one
## UTF-16 unit but two UTF-8 bytes, and "🙂" is two UTF-16 units but four bytes.
## Handing a byte offset to the editor would put the caret in the wrong place,
## and a replacement spliced at a byte offset derived from a UTF-16 selection
## would cut a character in half.
##
## So the text is decoded once into runes, each tagged with both its UTF-16
## offset (for talking to the editor) and its byte offset (for slicing the
## string). Matching then compares runes, which also makes case-insensitive
## matching correct for non-ASCII letters without the length changes that
## lowercasing whole strings can introduce.

import std/unicode

type
  SearchOpts* = object
    ## How to match. Both default to off, i.e. a case-insensitive substring
    ## search, which is what the find bar starts with.
    matchCase*: bool   ## "Aa": distinguish upper and lower case
    wholeWord*: bool   ## "ab": match only when not flanked by word characters

  Match* = object
    ## One match, as a half-open range of UTF-16 code units: [start, stop).
    start*: int
    stop*: int

  FindResult* = object
    ## The outcome of a search.
    matches*: seq[Match]  ## the matches, in document order (capped, see `capped`)
    total*: int           ## how many matches exist, even if fewer are returned
    capped*: bool         ## true when `total` exceeds the returned matches

  ReplaceResult* = object
    ## The outcome of a replace: the whole new text and where the selection
    ## should end up, mirroring `editing.EditResult`.
    text*: string
    selStart*: int        ## new selection start (UTF-16 offset)
    selEnd*: int          ## new selection end (UTF-16 offset)
    replaced*: int        ## how many matches were replaced

  Decoded = object
    ## A string taken apart once so both offset systems are on hand.
    runes: seq[Rune]
    u16At: seq[int]       ## UTF-16 offset of each rune
    byteAt: seq[int]      ## byte offset of each rune
    u16Len: int           ## total length in UTF-16 code units

const
  DefaultMatchLimit* = 10_000
    ## How many matches a single search returns by default. A document with more
    ## than this many hits is a search too broad to navigate anyway; the true
    ## count is still reported in `total` so nothing is silently dropped.

func utf16Len(r: Rune): int =
  ## Code units this rune occupies in UTF-16: astral characters are a surrogate
  ## pair, everything else is one unit.
  if r.int32 > 0xFFFF: 2 else: 1

func decode(s: string): Decoded =
  ## Split `s` into runes, recording where each one starts in both offset
  ## systems. Invalid bytes are consumed one at a time by `fastRuneAt`, so a
  ## malformed string still decodes to something rather than raising.
  var i = 0
  while i < s.len:
    let byteStart = i
    var r: Rune
    fastRuneAt(s, i, r, true)  # advances i past the rune
    result.runes.add(r)
    result.byteAt.add(byteStart)
    result.u16At.add(result.u16Len)
    result.u16Len += utf16Len(r)
  # One-past-the-end entries, so a range ending at the last rune can be sliced
  # without special-casing.
  result.byteAt.add(s.len)
  result.u16At.add(result.u16Len)

func isWordRune(r: Rune): bool =
  ## What counts as "inside a word" for the whole-word option: letters, digits
  ## and the underscore, the same set editors conventionally use. Non-ASCII
  ## letters count, so searching "naive" whole-word does not match inside
  ## "naiveté".
  let c = r.int32
  if c < 128:
    let ch = char(c)
    ch in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z', '_'}
  else:
    isAlpha(r)

func sameRune(a, b: Rune, matchCase: bool): bool =
  ## Compare two runes, folding case unless the caller asked for an exact match.
  ## Folding per rune (rather than lowercasing whole strings up front) keeps rune
  ## counts stable, so offsets computed here always line up with the original.
  if matchCase: a == b else: toLower(a) == toLower(b)

func matchesAt(hay, needle: Decoded, at: int, opts: SearchOpts): bool =
  ## Does `needle` occur in `hay` starting at rune index `at`?
  if at + needle.runes.len > hay.runes.len:
    return false
  for k in 0 ..< needle.runes.len:
    if not sameRune(hay.runes[at + k], needle.runes[k], opts.matchCase):
      return false
  if opts.wholeWord:
    # Reject a hit glued to a word character on either side.
    if at > 0 and isWordRune(hay.runes[at - 1]):
      return false
    let after = at + needle.runes.len
    if after < hay.runes.len and isWordRune(hay.runes[after]):
      return false
  true

func runeMatches(hay, needle: Decoded, opts: SearchOpts,
                 limit: int): tuple[ranges: seq[Slice[int]], total: int] =
  ## Every non-overlapping occurrence of `needle` in `hay`, as rune index ranges.
  ## Scanning resumes after a hit, so "aa" in "aaaa" is two matches, not three.
  ## `limit` caps how many ranges are collected; counting continues past the cap
  ## so the caller can report a truthful total.
  if needle.runes.len == 0:
    return (@[], 0)
  var i = 0
  while i <= hay.runes.len - needle.runes.len:
    if matchesAt(hay, needle, i, opts):
      inc result.total
      if limit <= 0 or result.ranges.len < limit:
        result.ranges.add(i ..< i + needle.runes.len)
      i += needle.runes.len
    else:
      inc i

func toMatch(hay: Decoded, r: Slice[int]): Match =
  ## A rune index range as the UTF-16 range the editor understands.
  Match(start: hay.u16At[r.a], stop: hay.u16At[r.b + 1])

func find*(text, needle: string, opts: SearchOpts,
           limit = DefaultMatchLimit): FindResult =
  ## Every match of `needle` in `text`, as UTF-16 ranges. An empty needle matches
  ## nothing (rather than everything), so an empty find box clears the highlights
  ## instead of selecting the whole document.
  if needle.len == 0:
    return FindResult(matches: @[], total: 0, capped: false)
  let
    hay = decode(text)
    ndl = decode(needle)
    (ranges, total) = runeMatches(hay, ndl, opts, limit)
  result.total = total
  result.capped = total > ranges.len
  for r in ranges:
    result.matches.add(toMatch(hay, r))

func spliceAll(text: string, hay: Decoded, ranges: openArray[Slice[int]],
               replacement: string): string =
  ## Replace every rune range with `replacement`, working on byte offsets. All
  ## ranges refer to the ORIGINAL text and are applied in one pass, so the
  ## replacement is never re-scanned: replacing "a" with "aa" doubles each match
  ## once instead of looping.
  var cursor = 0  # byte offset in `text` of the first byte not yet copied
  for r in ranges:
    let
      startByte = hay.byteAt[r.a]
      stopByte = hay.byteAt[r.b + 1]
    result.add(text[cursor ..< startByte])
    result.add(replacement)
    cursor = stopByte
  result.add(text[cursor .. ^1])

func replaceAll*(text, needle, replacement: string,
                 opts: SearchOpts): ReplaceResult =
  ## Replace every match in one step. The whole thing is a single edit, so it is
  ## a single undo step for the caller. The caret lands after the last inserted
  ## replacement; with nothing to replace the text and caret are untouched.
  result = ReplaceResult(text: text, selStart: 0, selEnd: 0, replaced: 0)
  if needle.len == 0:
    return
  let
    hay = decode(text)
    ndl = decode(needle)
    (ranges, total) = runeMatches(hay, ndl, opts, limit = 0)
  if total == 0:
    return
  result.text = spliceAll(text, hay, ranges, replacement)
  result.replaced = total
  # Caret after the final replacement: everything before the last match, plus
  # the growth from every earlier replacement, plus the replacement itself.
  let
    replU16 = decode(replacement).u16Len
    needleU16 = decode(needle).u16Len
    last = ranges[^1]
    shift = (ranges.len - 1) * (replU16 - needleU16)
  result.selStart = hay.u16At[last.a] + shift + replU16
  result.selEnd = result.selStart

func replaceOne*(text, needle, replacement: string, opts: SearchOpts,
                 selStart, selEnd: int): ReplaceResult =
  ## Replace the match the selection currently covers, the way a Replace button
  ## behaves in every editor: if the selection is exactly a match, swap it and
  ## leave the caret after the inserted text; otherwise change nothing (the
  ## caller then moves to the next match and can press Replace again).
  result = ReplaceResult(text: text, selStart: selStart, selEnd: selEnd,
                         replaced: 0)
  if needle.len == 0:
    return
  let
    lo = min(selStart, selEnd)
    hi = max(selStart, selEnd)
    hay = decode(text)
    ndl = decode(needle)
  # Locate the selection in rune space; it must land exactly on rune boundaries
  # and span exactly one match for this to be a replace rather than a no-op.
  var startRune = -1
  for i in 0 .. hay.runes.len:
    if hay.u16At[i] == lo:
      startRune = i
      break
  if startRune < 0:
    return
  let stopRune = startRune + ndl.runes.len
  if stopRune > hay.runes.len or hay.u16At[stopRune] != hi:
    return
  if not matchesAt(hay, ndl, startRune, opts):
    return
  result.text = spliceAll(text, hay, [startRune ..< stopRune], replacement)
  result.replaced = 1
  result.selStart = lo + decode(replacement).u16Len
  result.selEnd = result.selStart
