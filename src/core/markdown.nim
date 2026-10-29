## Wrapper around the vendored nim-markdown library (src/vendor/markdown).
## Returns the HTML fragment for a markdown source, GitHub-flavored (tables and
## strikethrough enabled). Raw inline HTML (for example the `<u>` emitted by the
## underline shortcut) passes through untouched, which is what we want: the app
## renders the local user's own document, so no sanitizer is added.
##
## Two things are added to the library's output: task list markers become
## read-only checkboxes, and every heading gets the `id` its own table of
## contents links to, so `[see below](#build-from-source)` has somewhere to land.
##
## Rendering never raises out of here. If the parser throws, we return a small
## inline error block plus the escaped source, so a bad document degrades to
## readable text instead of taking down the preview.

import std/[strutils, tables, unicode]
import ../vendor/markdown/markdown as md

func taskBox(kind: string): string =
  ## A read-only checkbox for a task list item. The preview is read-only (editing
  ## happens in the raw pane), so the box is disabled.
  case kind
  of "checked": """<input type="checkbox" checked disabled> """
  else: """<input type="checkbox" disabled> """

func convertTaskItems*(html: string): string =
  ## Turn task-list markers at the start of a list item into read-only checkboxes.
  ## The markdown library renders `- [x] foo` literally as `<li>[x] foo`, so we
  ## detect that (tight lists) and the loose `<li>\n<p>[x] ` form. Only the
  ## standard markers are handled: `[ ]` unchecked and `[x]`/`[X]` done. Any other
  ## bracketed marker is left as plain text.
  html.multiReplace(
    ("<li>[ ] ", "<li class=\"task\">" & taskBox("")),
    ("<li>[x] ", "<li class=\"task\">" & taskBox("checked")),
    ("<li>[X] ", "<li class=\"task\">" & taskBox("checked")),
    ("<li>\n<p>[ ] ", "<li class=\"task\">\n<p>" & taskBox("")),
    ("<li>\n<p>[x] ", "<li class=\"task\">\n<p>" & taskBox("checked")),
    ("<li>\n<p>[X] ", "<li class=\"task\">\n<p>" & taskBox("checked")),
  )

func stripTags(s: string): string =
  ## The visible text of an HTML fragment: everything outside `<...>`. Used only
  ## to build a heading's anchor, where markup inside the heading (a `<code>`
  ## span, an `<em>`) must not become part of the name.
  result = newStringOfCap(s.len)
  var depth = 0
  for c in s:
    case c
    of '<': depth += 1
    of '>': (if depth > 0: depth -= 1)
    else:
      if depth == 0: result.add c

proc headingSlug*(text: string): string =
  ## The anchor name for a heading, following the convention every markdown host
  ## uses: lowercase, punctuation dropped, spaces turned into hyphens. It is what
  ## a document's own table of contents links to, so `## Build from source`
  ## becomes `#build-from-source`.
  ##
  ## Letters outside ASCII are letters too, so a heading written in another
  ## script keeps its own name (lowercased by the same rules) rather than
  ## ending up with no anchor at all.
  let plain = stripTags(text).multiReplace(
    ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"))
  var slug = newStringOfCap(plain.len)
  for r in plain.runes:
    let cp = int32(r)
    if cp < 128:
      let c = char(cp)
      case c
      of 'A' .. 'Z': slug.add chr(ord(c) - ord('A') + ord('a'))
      of 'a' .. 'z', '0' .. '9', '-', '_': slug.add c
      of ' ', '\t', '\n', '\r', '\f', '\v': slug.add '-'
      else: discard
    elif r.isAlpha():
      slug.add $r.toLower()
  # A heading made only of punctuation leaves nothing behind but the hyphens its
  # spaces turned into, and those are not a name.
  slug.strip(chars = {'-'})

proc addHeadingIds*(html: string): string =
  ## Give every heading an `id` derived from its text, so links within the
  ## document (`[see below](#build-from-source)`) have something to land on. A
  ## heading that already carries an `id` is left exactly as it is, and repeated
  ## headings get `-1`, `-2`, ... appended the way markdown hosts number them.
  var taken = initTable[string, bool]()
  var counter = initTable[string, int]()
  # A level whose closing tag has already been searched for in vain: no opener
  # further along can find one either, so the scan is not repeated. Without this
  # a document of unclosed `<h1>`s would be re-scanned to the end for each one.
  var noCloser: set[char]
  result = newStringOfCap(html.len + 64)
  var i = 0
  while i < html.len:
    if html[i] == '<':
      # A code sample written as raw HTML keeps whatever it says verbatim; a
      # heading quoted inside one is text, not a heading.
      if i + 4 <= html.len and html[i + 1 .. min(i + 3, html.high)] == "pre":
        let close = html.find("</pre>", i)
        let stop = if close < 0: html.len else: close + "</pre>".len
        result.add html[i ..< stop]
        i = stop
        continue
      # Only "<h1>" .. "<h6>" with no attributes: a heading the renderer emitted.
      # Anything else (raw HTML the document carried through, with attributes of
      # its own) is passed along untouched.
      if i + 3 < html.len and html[i + 1] == 'h' and
         html[i + 2] in {'1' .. '6'} and html[i + 3] == '>' and
         html[i + 2] notin noCloser:
        let level = html[i + 2]
        let closing = "</h" & level & ">"
        let bodyStart = i + 4
        let bodyEnd = html.find(closing, bodyStart)
        if bodyEnd < 0:
          noCloser.incl level
          result.add html[i]
          i += 1
          continue
        let body = html[bodyStart ..< bodyEnd]
        let base = headingSlug(body)
        if base.len == 0:
          # A heading made only of punctuation or an image has no name of its own.
          result.add html[i ..< bodyEnd + closing.len]
          i = bodyEnd + closing.len
          continue
        # Number a repeat, and keep numbering until the name is free: a document
        # can perfectly well hold both "Notes" twice and a heading called
        # "Notes 1", and they must not end up claiming the same anchor.
        var slug = base
        if taken.hasKey(slug):
          var n = counter.getOrDefault(base, 0)
          while true:
            n += 1
            slug = base & "-" & $n
            if not taken.hasKey(slug): break
          counter[base] = n
        taken[slug] = true
        result.add "<h" & level & " id=\"" & slug & "\">" & body & closing
        i = bodyEnd + closing.len
        continue
    result.add html[i]
    i += 1

func escapeHtml(s: string): string =
  ## Minimal HTML escaping for the fallback path.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

proc renderMarkdown*(source: string): string =
  ## Render markdown to an HTML fragment. On a rendering error, return an inline
  ## error notice followed by the source as preformatted text so the preview
  ## still shows something useful.
  try:
    result = addHeadingIds(convertTaskItems(md.markdown(source, config = md.initGfmConfig())))
  except CatchableError as e:
    result = "<div class=\"render-error\">Could not render markdown: " &
      escapeHtml(e.msg) & "</div>\n<pre class=\"render-fallback\">" &
      escapeHtml(source) & "</pre>"

proc renderOutcome*(source: string): tuple[html: string, ok: bool, error: string] =
  ## Like renderMarkdown but also reports whether rendering succeeded, for
  ## callers (tests, logging) that want to know.
  try:
    let html = addHeadingIds(convertTaskItems(md.markdown(source, config = md.initGfmConfig())))
    (html, true, "")
  except CatchableError as e:
    let fallback = "<div class=\"render-error\">Could not render markdown: " &
      escapeHtml(e.msg) & "</div>\n<pre class=\"render-fallback\">" &
      escapeHtml(source) & "</pre>"
    (fallback, false, e.msg)

when isMainModule:
  # Tiny manual check.
  echo renderMarkdown("# Hi\n\n**bold** and <u>under</u>\n\n- a\n- b\n\n`code`")
