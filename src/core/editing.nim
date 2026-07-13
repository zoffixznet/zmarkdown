## Pure text-transform procs for the editor shortcuts.
##
## Every proc takes the full editor text plus a selection (start/end offsets in
## UTF-16 code units, matching what a browser textarea reports) and returns the
## new text together with the new selection. No GUI, no side effects, so these
## are unit-tested in isolation.
##
## Offsets are treated as opaque indices into the string measured the same way
## the caller measures them. The JavaScript adapter passes the textarea's
## `selectionStart` / `selectionEnd`, which are UTF-16 code unit offsets. To keep
## the arithmetic identical on both sides we operate on the string as a sequence
## of UTF-16 code units here as well; for the ASCII markup we insert this is
## equivalent to byte or rune counting, and for the surrounding user text we only
## ever slice at the offsets the browser gave us, so no re-measuring is needed.

type
  EditResult* = object
    ## The outcome of an edit: the whole new text and where the selection
    ## should end up afterwards.
    text*: string          ## the full replacement text for the editor
    selStart*: int         ## new selection start (UTF-16 offset)
    selEnd*: int           ## new selection end (UTF-16 offset)

func clampOffset(s: string, off: int): int =
  ## Keep an incoming offset within the string bounds so a stale or bogus
  ## selection from the UI cannot index out of range.
  if off < 0: 0
  elif off > s.len: s.len
  else: off

func wrapOrInsert(text: string, selStart, selEnd: int,
                  prefix, suffix: string): EditResult =
  ## Core of the bold/italic/underline shortcuts.
  ##
  ## If a selection exists, wrap it as `prefix & selection & suffix` and leave the
  ## wrapped text selected (between the markers). If nothing is selected, insert
  ## `prefix & suffix` and put the caret between them so the next character typed
  ## lands inside the markers.
  let
    a = clampOffset(text, selStart)
    b0 = clampOffset(text, selEnd)
    # Normalize so a <= b even if the UI reports them reversed.
    lo = min(a, b0)
    hi = max(a, b0)
    before = text[0 ..< lo]
    selected = text[lo ..< hi]
    after = text[hi .. ^1]
  if lo == hi:
    # No selection: insert both markers, caret between them.
    result.text = before & prefix & suffix & after
    result.selStart = lo + prefix.len
    result.selEnd = result.selStart
  else:
    # Selection: wrap it, keep the inner text selected.
    result.text = before & prefix & selected & suffix & after
    result.selStart = lo + prefix.len
    result.selEnd = result.selStart + selected.len

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
  let
    a = clampOffset(text, selStart)
    b0 = clampOffset(text, selEnd)
    lo = min(a, b0)
    hi = max(a, b0)
    before = text[0 ..< lo]
    after = text[hi .. ^1]
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
    a = clampOffset(text, selStart)
    b0 = clampOffset(text, selEnd)
    lo = min(a, b0)
    hi = max(a, b0)
    label = if lo == hi: "link text" else: text[lo ..< hi]
    full = "[" & label & "](" & linkUrl & ")"
  # Select the label (between '[' and ']').
  insertBetween(text, selStart, selEnd, full, 1, 1 + label.len)

func applyImage*(text: string, selStart, selEnd: int): EditResult =
  ## Image button: insert `![alt text](https://example.com/image.png)`. If text
  ## is selected, use it as the alt text. The alt text portion is left selected.
  let
    a = clampOffset(text, selStart)
    b0 = clampOffset(text, selEnd)
    lo = min(a, b0)
    hi = max(a, b0)
    alt = if lo == hi: "alt text" else: text[lo ..< hi]
    full = "![" & alt & "](" & imageUrl & ")"
  # Select the alt text (between '![' and ']').
  insertBetween(text, selStart, selEnd, full, 2, 2 + alt.len)
