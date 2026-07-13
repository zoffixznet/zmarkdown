import std/unittest
import "../src/core/editing"

suite "bold":
  test "wraps a selection":
    # "hello world", select "world" (offsets 6..11)
    let r = applyBold("hello world", 6, 11)
    check r.text == "hello **world**"
    # inner text stays selected, between the markers
    check r.selStart == 8
    check r.selEnd == 13
    check r.text[r.selStart ..< r.selEnd] == "world"

  test "empty caret inserts markers with caret in the middle":
    let r = applyBold("ab", 1, 1)
    check r.text == "a****b"
    check r.selStart == 3
    check r.selEnd == 3
    # the caret sits between the two pairs of asterisks
    check r.text[0 ..< r.selStart] == "a**"
    check r.text[r.selStart .. ^1] == "**b"

  test "reversed selection is normalized":
    let r = applyBold("hello world", 11, 6)
    check r.text == "hello **world**"
    check r.text[r.selStart ..< r.selEnd] == "world"

suite "italic":
  test "wraps a selection with single asterisks":
    let r = applyItalic("hello world", 0, 5)
    check r.text == "*hello* world"
    check r.selStart == 1
    check r.selEnd == 6
    check r.text[r.selStart ..< r.selEnd] == "hello"

  test "empty caret inserts a pair with caret in the middle":
    let r = applyItalic("", 0, 0)
    check r.text == "**"
    check r.selStart == 1
    check r.selEnd == 1

suite "underline":
  test "wraps a selection in u tags":
    let r = applyUnderline("hello", 0, 5)
    check r.text == "<u>hello</u>"
    check r.text[r.selStart ..< r.selEnd] == "hello"
    check r.selStart == 3

  test "empty caret inserts u tags with caret between them":
    let r = applyUnderline("xy", 1, 1)
    check r.text == "x<u></u>y"
    check r.selStart == 4
    check r.selEnd == 4
    check r.text[0 ..< r.selStart] == "x<u>"
    check r.text[r.selStart .. ^1] == "</u>y"

suite "link":
  test "empty caret inserts sample link with label selected":
    let r = applyLink("", 0, 0)
    check r.text == "[link text](https://example.com)"
    check r.text[r.selStart ..< r.selEnd] == "link text"
    # label is the part between the brackets
    check r.selStart == 1

  test "selection becomes the link label":
    let r = applyLink("see docs here", 4, 8)  # "docs"
    check r.text == "see [docs](https://example.com) here"
    check r.text[r.selStart ..< r.selEnd] == "docs"

suite "image":
  test "empty caret inserts sample image with alt selected":
    let r = applyImage("", 0, 0)
    check r.text == "![alt text](https://example.com/image.png)"
    check r.text[r.selStart ..< r.selEnd] == "alt text"
    check r.selStart == 2

  test "selection becomes the alt text":
    let r = applyImage("logo", 0, 4)
    check r.text == "![logo](https://example.com/image.png)"
    check r.text[r.selStart ..< r.selEnd] == "logo"

suite "bounds safety":
  test "out-of-range offsets are clamped, no crash":
    let r = applyBold("hi", -5, 999)
    check r.text == "**hi**"
    check r.text[r.selStart ..< r.selEnd] == "hi"
