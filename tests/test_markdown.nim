import std/unittest
import std/strutils
import "../src/core/markdown"

suite "basic markdown to html":
  test "heading":
    check renderMarkdown("# Title").contains("<h1")
    check renderMarkdown("# Title").contains("Title")

  test "bold":
    check renderMarkdown("**bold**").contains("<strong>bold</strong>")

  test "unordered list":
    let html = renderMarkdown("- one\n- two")
    check html.contains("<ul>")
    check html.contains("<li>one</li>")
    check html.contains("<li>two</li>")

  test "fenced code block":
    let html = renderMarkdown("```\nlet x = 1\n```")
    check html.contains("<pre>")
    check html.contains("<code")
    check html.contains("let x = 1")

  test "inline code":
    check renderMarkdown("`code`").contains("<code>code</code>")

suite "raw html passthrough":
  test "u tags survive rendering":
    let html = renderMarkdown("this is <u>underlined</u> text")
    check html.contains("<u>underlined</u>")

  test "u tags survive inside a paragraph with other markdown":
    let html = renderMarkdown("**bold** and <u>under</u>")
    check html.contains("<strong>bold</strong>")
    check html.contains("<u>under</u>")

suite "gfm features":
  test "table renders":
    let html = renderMarkdown("| a | b |\n| - | - |\n| 1 | 2 |")
    check html.contains("<table")
    check html.contains("<td>1</td>")

suite "error handling":
  test "rendering never raises, returns a string for any input":
    # Feed a variety of odd inputs; none should raise out of the wrapper.
    for s in ["", "   ", "]]][[", "```unterminated", "<u><b>", "# " & repeat("x", 5000)]:
      let html = renderMarkdown(s)
      check html.len >= 0  # the point is that the call returns without raising

  test "renderOutcome reports success on valid input":
    let (html, ok, err) = renderOutcome("# Hi")
    check ok
    check err.len == 0
    check html.contains("<h1")

suite "task list checkboxes":
  test "standard markers become read-only checkboxes":
    let h = renderMarkdown("- [x] done\n- [ ] todo\n- [X] caps")
    check h.contains("<li class=\"task\">")
    check h.contains("type=\"checkbox\" checked disabled")
    check not h.contains("[x]")
    check not h.contains("[ ]")
    check not h.contains("[X]")

  test "loose markers become checkboxes":
    let h = renderMarkdown("- [x] a\n\n- [ ] b")
    check h.contains("<li class=\"task\">")
    check h.contains("type=\"checkbox\" checked disabled")
    check not h.contains("[x]")

  test "unknown markers like [~] are left as plain text":
    let h = renderMarkdown("- [~] partial\n- [x] done")
    check h.contains("[~]")                                 # not converted
    check not h.contains("task-partial")
    check h.contains("type=\"checkbox\" checked disabled")  # [x] still converts

  test "a normal list is left alone":
    let h = renderMarkdown("- one\n- two")
    check not h.contains("checkbox")
    check not h.contains("li class=\"task\"")

suite "heading anchors":
  test "a slug is lowercase words joined by hyphens":
    check headingSlug("Build from source") == "build-from-source"
    check headingSlug("Get a Prebuilt Binary") == "get-a-prebuilt-binary"

  test "punctuation is dropped, hyphens and underscores kept":
    check headingSlug("What's new? (2026)") == "whats-new-2026"
    check headingSlug("read_me: the well-known parts") ==
      "read_me-the-well-known-parts"

  test "markup inside a heading is not part of its name":
    check headingSlug("The <code>init</code> step") == "the-init-step"
    check headingSlug("Fish &amp; chips") == "fish--chips"

  test "letters outside ASCII are kept":
    check headingSlug("Привет мир") == "привет-мир"
    check headingSlug("Café Life") == "café-life"

  test "a heading with no letters at all has no slug":
    check headingSlug("!!! ???") == ""
    check headingSlug("") == ""

  test "headings are rendered with the id their own links use":
    let h = renderMarkdown("# Build From Source\n\n[go](#build-from-source)")
    check h.contains("<h1 id=\"build-from-source\">Build From Source</h1>")
    check h.contains("href=\"#build-from-source\"")

  test "every heading level gets an id":
    for level in 1 .. 6:
      let h = renderMarkdown(repeat("#", level) & " Deep Heading")
      check h.contains("<h" & $level & " id=\"deep-heading\">")

  test "repeated headings are numbered rather than sharing an id":
    let h = renderMarkdown("# Notes\n\n# Notes\n\n# Notes")
    check h.contains("<h1 id=\"notes\">")
    check h.contains("<h1 id=\"notes-1\">")
    check h.contains("<h1 id=\"notes-2\">")

  test "a heading whose own name collides with a numbered one still gets its own":
    # "Foo", "Foo" and "Foo 1" all want to be #foo-1; only one may have it, and
    # every heading must still end up reachable.
    let h = renderMarkdown("# Foo\n\n# Foo\n\n# Foo 1\n\n# Foo")
    var ids: seq[string]
    var i = 0
    while true:
      let at = h.find("id=\"", i)
      if at < 0: break
      let stop = h.find('"', at + 4)
      ids.add(h[at + 4 ..< stop])
      i = stop
    check ids.len == 4
    check ids[0] == "foo"
    for k in 0 ..< ids.len:
      for j in k + 1 ..< ids.len:
        check ids[k] != ids[j]

  test "a heading quoted inside a raw html code sample is left as text":
    let h = renderMarkdown("<pre><code>&lt;h1&gt;x&lt;/h1&gt;</code></pre>\n")
    check not h.contains("id=")
    check addHeadingIds("<pre><h1>literal</h1></pre>") ==
      "<pre><h1>literal</h1></pre>"

  test "many unclosed heading tags do not take quadratic time":
    # Each unclosed opener used to rescan to the end of the document.
    let noisy = repeat("<h1>", 20000)
    check addHeadingIds(noisy) == noisy

  test "a heading with nothing to name it is left alone":
    let h = renderMarkdown("# ???")
    check h.contains("<h1>???</h1>")

  test "raw heading html that already has attributes is untouched":
    let h = addHeadingIds("""<h2 id="mine">Kept</h2><h2 class="x">Also kept</h2>""")
    check h == """<h2 id="mine">Kept</h2><h2 class="x">Also kept</h2>"""

  test "an unclosed heading tag does not lose text":
    check addHeadingIds("<h1>no end").contains("no end")

suite "html entities":
  test "numeric character references decode to the character":
    for (source, expected) in [
      ("&#931;", "Σ"),        # decimal
      ("&#0931;", "Σ"),       # leading zero
      ("&#x3A3;", "Σ"),       # hex
      ("&#X3a3;", "Σ"),       # hex, either case anywhere
      ("&#63;", "?"),
      ("A &#931; B", "A Σ B"),
    ]:
      check renderMarkdown(source).contains(expected)

  test "named entities decode, and the ones html needs stay escaped":
    check renderMarkdown("&Uuml;").contains("Ü")
    check renderMarkdown("&amp;").contains("&amp;")

  test "an unknown name is shown as written":
    check renderMarkdown("&bogus;").contains("&amp;bogus;")

  test "code points that are not characters become the replacement character":
    check renderMarkdown("&#0;").contains("�")
    check renderMarkdown("&#xD800;").contains("�")

  test "out-of-range and malformed references are shown as written":
    for (source, expected) in [
      ("&#1114112;", "&amp;#1114112;"),  # one past U+10FFFF
      ("&#;", "&amp;#;"),
      ("&#x;", "&amp;#x;"),
      ("&#12a;", "&amp;#12a;"),
    ]:
      check renderMarkdown(source).contains(expected)
