## Pure text-transform procs for the editor shortcuts.
##
## Every proc takes the full editor text plus a selection and returns the new
## text together with the new selection. No GUI, no side effects, so these are
## unit-tested in isolation.
##
## Offsets crossing this module's boundary are UTF-16 code unit offsets, because
## that is what a browser textarea's `selectionStart` / `selectionEnd` report and
## what `setSelectionRange` expects. Nim strings are UTF-8 bytes, and the two
## stop agreeing the moment the document holds anything outside ASCII: "e" with
## an acute accent is one UTF-16 unit and two bytes, an emoji is two units and
## four bytes. So an incoming offset is translated to a byte offset before the
## string is ever sliced, and every offset handed back is a unit offset again.
## Slicing at a raw byte offset taken from a unit offset would cut a character
## in half - bold applied to a word below an emoji is enough to do it.
##
## The markup these procs insert is ASCII throughout, so its byte length and its
## unit length are the same number; that is relied on where a marker's length is
## added to an offset.

import std/unicode

import indent
export indent

type
  EditResult* = object
    ## The outcome of an edit: the whole new text and where the selection
    ## should end up afterwards.
    text*: string          ## the full replacement text for the editor
    selStart*: int         ## new selection start (UTF-16 offset)
    selEnd*: int           ## new selection end (UTF-16 offset)

  UnitMap = seq[int]
    ## Byte offset of every UTF-16 code unit boundary in a string, with a final
    ## one-past-the-end entry, so `m[units]` is where to cut the string for a
    ## selection offset of `units`. The low half of a surrogate pair is not a
    ## place a string can be cut at, so it maps to the start of its own
    ## character: an offset landing there is pulled back to the character
    ## boundary instead of splitting it.

func unitMap(s: string): UnitMap =
  ## Walk the string once and record where each UTF-16 code unit begins.
  ## Malformed bytes are consumed one at a time by `fastRuneAt`, so a string
  ## that is not valid UTF-8 still maps to something rather than raising.
  result = @[]
  var i = 0
  while i < s.len:
    let start = i
    var r: Rune
    fastRuneAt(s, i, r, true)  # advances i past the rune
    result.add start
    if r.int32 > 0xFFFF: result.add start  # the low surrogate cuts nowhere
  result.add s.len

func clampUnits(m: UnitMap, off: int): int =
  ## Keep an incoming offset within the string, so a stale or bogus selection
  ## from the UI cannot index out of range, and off the low half of a surrogate
  ## pair, which is not a place the string can be cut at.
  ##
  ## The offset itself is pulled back, not just the byte it maps to. Snapping
  ## only the cut would leave the returned selection counting a half character
  ## that the text handed back no longer contains, and every offset derived from
  ## it would sit one code unit too far right.
  var i = if off < 0: 0 elif off > m.high: m.high else: off
  # Two entries with the same byte offset are a character and its low surrogate;
  # nothing else can repeat, since every rune advances the byte offset.
  if i > 0 and m[i] == m[i - 1]: dec i
  i

func lineStarts(text: string, m: UnitMap): seq[int] =
  ## The unit offset at which every line begins, first line included. A newline
  ## is one byte and one unit, so the byte under a unit boundary is all that has
  ## to be looked at.
  result = @[0]
  for i in 0 ..< m.high:
    if text[m[i]] == '\n': result.add i + 1

func lineIndexAt(starts: seq[int], units: int): int =
  ## Which line a unit offset falls on.
  result = 0
  for i, start in starts:
    if start <= units: result = i
    else: break

func wrapOrInsert(text: string, selStart, selEnd: int,
                  prefix, suffix: string): EditResult =
  ## Core of the bold/italic/underline shortcuts.
  ##
  ## If a selection exists, wrap it as `prefix & selection & suffix` and leave the
  ## wrapped text selected (between the markers). If nothing is selected, insert
  ## `prefix & suffix` and put the caret between them so the next character typed
  ## lands inside the markers.
  let
    m = unitMap(text)
    a = clampUnits(m, selStart)
    b = clampUnits(m, selEnd)
    # Normalize so lo <= hi even if the UI reports them reversed.
    lo = min(a, b)
    hi = max(a, b)
    before = text[0 ..< m[lo]]
    selected = text[m[lo] ..< m[hi]]
    after = text[m[hi] .. ^1]
  if lo == hi:
    # No selection: insert both markers, caret between them.
    result.text = before & prefix & suffix & after
    result.selStart = lo + prefix.len
    result.selEnd = result.selStart
  else:
    # Selection: wrap it, keep the inner text selected.
    result.text = before & prefix & selected & suffix & after
    result.selStart = lo + prefix.len
    result.selEnd = result.selStart + (hi - lo)

func applyBold*(text: string, selStart, selEnd: int): EditResult =
  ## Ctrl+B: `**selection**`, or `****` with the caret in the middle.
  wrapOrInsert(text, selStart, selEnd, "**", "**")

func applyItalic*(text: string, selStart, selEnd: int): EditResult =
  ## Ctrl+I: `*selection*`, or `**` with the caret in the middle.
  wrapOrInsert(text, selStart, selEnd, "*", "*")

func applyUnderline*(text: string, selStart, selEnd: int): EditResult =
  ## Ctrl+U: `<u>selection</u>`, or `<u></u>` with the caret between the tags.
  ## Markdown has no underline, so this emits inline HTML which the renderer
  ## passes through.
  wrapOrInsert(text, selStart, selEnd, "<u>", "</u>")

func insertBetween(text: string, selStart, selEnd: int,
                   full: string, selInStart, selInEnd: int): EditResult =
  ## Replace the current selection (or insert at the caret) with `full`, and
  ## select the sub-range [selInStart, selInEnd) within the inserted text so the
  ## visible part (link text / alt text) is highlighted for immediate typing.
  ## Both sub-range offsets are unit offsets within `full`.
  let
    m = unitMap(text)
    a = clampUnits(m, selStart)
    b = clampUnits(m, selEnd)
    lo = min(a, b)
    hi = max(a, b)
    before = text[0 ..< m[lo]]
    after = text[m[hi] .. ^1]
  result.text = before & full & after
  result.selStart = lo + selInStart
  result.selEnd = lo + selInEnd

const
  linkUrl = "https://example.com"
  imageUrl = "https://example.com/image.png"

func applyLink*(text: string, selStart, selEnd: int): EditResult =
  ## Link button: insert `[link text](https://example.com)`. If text is
  ## selected, use it as the visible link text: `[selection](https://example.com)`.
  ## The visible text portion is left selected so it is obvious which part is the
  ## label and which is the URL.
  let
    m = unitMap(text)
    a = clampUnits(m, selStart)
    b = clampUnits(m, selEnd)
    lo = min(a, b)
    hi = max(a, b)
    label = if lo == hi: "link text" else: text[m[lo] ..< m[hi]]
    labelUnits = if lo == hi: label.len else: hi - lo
    full = "[" & label & "](" & linkUrl & ")"
  # Select the label (between '[' and ']').
  insertBetween(text, selStart, selEnd, full, 1, 1 + labelUnits)

func applyImage*(text: string, selStart, selEnd: int): EditResult =
  ## Image button: insert `![alt text](https://example.com/image.png)`. If text
  ## is selected, use it as the alt text. The alt text portion is left selected.
  let
    m = unitMap(text)
    a = clampUnits(m, selStart)
    b = clampUnits(m, selEnd)
    lo = min(a, b)
    hi = max(a, b)
    alt = if lo == hi: "alt text" else: text[m[lo] ..< m[hi]]
    altUnits = if lo == hi: alt.len else: hi - lo
    full = "![" & alt & "](" & imageUrl & ")"
  # Select the alt text (between '![' and ']').
  insertBetween(text, selStart, selEnd, full, 2, 2 + altUnits)

func applyIndent*(text: string, selStart, selEnd: int;
                  unit = "\t"): EditResult =
  ## Tab: one level of indentation at the caret, or one at the front of every
  ## line the selection reaches into when it spans more than one.
  ##
  ## `unit` is what one level is - a tab, or the run of spaces the settings ask
  ## for. It is whitespace and so ASCII, which is what lets its byte length
  ## stand in for its length in code units below.
  ##
  ## A selection inside a single line is replaced by it, the way typing any
  ## other character replaces a selection. A selection across several lines
  ## indents them all and stays wrapped around them afterwards, so Tab can be
  ## pressed again to indent them further.
  let
    m = unitMap(text)
    a = clampUnits(m, selStart)
    b = clampUnits(m, selEnd)
    lo = min(a, b)
    hi = max(a, b)
    starts = lineStarts(text, m)
    first = lineIndexAt(starts, lo)
    reached = lineIndexAt(starts, hi)
  if reached == first:
    # Within one line: this is a character being typed, not a block being moved.
    return EditResult(
      text: text[0 ..< m[lo]] & unit & text[m[hi] .. ^1],
      selStart: lo + unit.len, selEnd: lo + unit.len)
  # A selection ending exactly where a line begins has not reached into that
  # line, so that line is not indented along with the rest.
  var last = reached
  if hi == starts[last]: dec last
  var built = text[0 ..< m[starts[first]]]
  for i in first .. last:
    let stop = if i < last: starts[i + 1] else: hi
    built.add unit
    built.add text[m[starts[i]] ..< m[stop]]
  built.add text[m[hi] .. ^1]
  # Every level went in at or before `hi`. The selection starts at the line
  # start, so the indentation that line just gained is inside it.
  EditResult(text: built, selStart: starts[first],
             selEnd: hi + (last - first + 1) * unit.len)

func leadingIndent(text: string, byteStart, byteEnd, width: int): int =
  ## How much indentation Shift+Tab takes off the front of one line: a single
  ## tab, or up to `width` spaces where the line is indented with spaces. Both
  ## are tried whichever way the settings are set, so a spaces-indented file
  ## still outdents properly while the preference says tabs. Zero for a line
  ## that is not indented, which is then left exactly as it is rather than
  ## losing a character of its own. Tabs and spaces are one byte and one unit
  ## each, so the count means the same thing in both systems.
  if byteStart >= byteEnd: return 0
  if text[byteStart] == '\t': return 1
  while result < width and byteStart + result < byteEnd and
        text[byteStart + result] == ' ':
    inc result

func applyOutdent*(text: string, selStart, selEnd: int;
                   width = DefaultTabWidth): EditResult =
  ## Shift+Tab: take one level of indentation off the front of every line the
  ## selection reaches into, or off the caret's own line when nothing is
  ## selected. Lines that are not indented are left alone, so one press cannot
  ## eat into the text of a block where only some lines are indented.
  ##
  ## `width` is how many spaces count as a level; a leading tab is always one
  ## level whatever it is set to.
  let
    m = unitMap(text)
    a = clampUnits(m, selStart)
    b = clampUnits(m, selEnd)
    lo = min(a, b)
    hi = max(a, b)
    starts = lineStarts(text, m)
    first = lineIndexAt(starts, lo)
  var last = lineIndexAt(starts, hi)
  if last > first and hi == starts[last]: dec last
  var
    built = text[0 ..< m[starts[first]]]
    cutBeforeLo = 0
    cutBeforeHi = 0
  for i in first .. last:
    let
      lineStart = starts[i]
      lineEnd = if i + 1 < starts.len: starts[i + 1] else: m.high
      cut = leadingIndent(text, m[lineStart], m[lineEnd], clampTabWidth(width))
    built.add text[m[lineStart + cut] ..< m[lineEnd]]
    # Only what was removed ahead of an offset moves that offset.
    if lo > lineStart: cutBeforeLo += min(cut, lo - lineStart)
    if hi > lineStart: cutBeforeHi += min(cut, hi - lineStart)
  let past = if last + 1 < starts.len: starts[last + 1] else: m.high
  built.add text[m[past] .. ^1]
  EditResult(text: built,
             selStart: max(lo - cutBeforeLo, 0),
             selEnd: max(hi - cutBeforeHi, 0))
