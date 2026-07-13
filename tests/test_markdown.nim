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
  test "tight markers become read-only checkboxes":
    let h = renderMarkdown("- [x] done\n- [ ] todo\n- [~] partial\n- [X] caps")
    check h.contains("<li class=\"task\">")
    check h.contains("type=\"checkbox\" checked disabled")
    check h.contains("class=\"task-partial\"")
    check not h.contains("[x]")
    check not h.contains("[ ]")
    check not h.contains("[~]")
    check not h.contains("[X]")

  test "loose markers become checkboxes":
    let h = renderMarkdown("- [x] a\n\n- [ ] b\n\n- [~] c")
    check h.contains("<li class=\"task\">")
    check h.contains("type=\"checkbox\" checked disabled")
    check h.contains("class=\"task-partial\"")
    check not h.contains("[x]")
    check not h.contains("[ ]")

  test "a normal list is left alone":
    let h = renderMarkdown("- one\n- two")
    check not h.contains("checkbox")
    check not h.contains("li class=\"task\"")
