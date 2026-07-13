## Wrapper around the `markdown` nimble package. Returns the HTML fragment for a
## markdown source, GitHub-flavored (tables and strikethrough enabled). Raw
## inline HTML (for example the `<u>` emitted by the underline shortcut) passes
## through untouched, which is what we want: the app renders the local user's own
## document, so no sanitizer is added.
##
## Rendering never raises out of here. If the parser throws, we return a small
## inline error block plus the escaped source, so a bad document degrades to
## readable text instead of taking down the preview.

import std/strutils
import pkg/markdown as md

func taskBox(kind: string): string =
  ## A read-only checkbox for a task list item. The preview is read-only (editing
  ## happens in the raw pane), so the box is disabled.
  case kind
  of "checked": """<input type="checkbox" checked disabled> """
  of "partial": """<input type="checkbox" class="task-partial" disabled> """
  else: """<input type="checkbox" disabled> """

func convertTaskItems*(html: string): string =
  ## Turn task-list markers at the start of a list item into read-only checkboxes.
  ## The markdown library renders `- [x] foo` literally as `<li>[x] foo`, so we
  ## detect that (tight lists) and the loose `<li>\n<p>[x] ` form. Markers:
  ## `[ ]` unchecked, `[x]`/`[X]` done, and `[~]` shown as an indeterminate
  ## (partial / in progress) box. `[~]` is not a standard marker; it is a
  ## convention some generated documents use, rendered here as a partial state.
  html.multiReplace(
    ("<li>[ ] ", "<li class=\"task\">" & taskBox("")),
    ("<li>[x] ", "<li class=\"task\">" & taskBox("checked")),
    ("<li>[X] ", "<li class=\"task\">" & taskBox("checked")),
    ("<li>[~] ", "<li class=\"task\">" & taskBox("partial")),
    ("<li>\n<p>[ ] ", "<li class=\"task\">\n<p>" & taskBox("")),
    ("<li>\n<p>[x] ", "<li class=\"task\">\n<p>" & taskBox("checked")),
    ("<li>\n<p>[X] ", "<li class=\"task\">\n<p>" & taskBox("checked")),
    ("<li>\n<p>[~] ", "<li class=\"task\">\n<p>" & taskBox("partial")),
  )

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
    result = convertTaskItems(md.markdown(source, config = md.initGfmConfig()))
  except CatchableError as e:
    result = "<div class=\"render-error\">Could not render markdown: " &
      escapeHtml(e.msg) & "</div>\n<pre class=\"render-fallback\">" &
      escapeHtml(source) & "</pre>"

proc renderOutcome*(source: string): tuple[html: string, ok: bool, error: string] =
  ## Like renderMarkdown but also reports whether rendering succeeded, for
  ## callers (tests, logging) that want to know.
  try:
    let html = convertTaskItems(md.markdown(source, config = md.initGfmConfig()))
    (html, true, "")
  except CatchableError as e:
    let fallback = "<div class=\"render-error\">Could not render markdown: " &
      escapeHtml(e.msg) & "</div>\n<pre class=\"render-fallback\">" &
      escapeHtml(source) & "</pre>"
    (fallback, false, e.msg)

when isMainModule:
  # Tiny manual check.
  echo renderMarkdown("# Hi\n\n**bold** and <u>under</u>\n\n- a\n- b\n\n`code`")
