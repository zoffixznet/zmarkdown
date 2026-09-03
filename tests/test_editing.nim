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

suite "offsets are UTF-16 code units, not bytes":
  # The editor counts a selection the way JavaScript does. Slicing the UTF-8
  # string at those numbers directly would cut a character in half the moment
  # anything above ASCII sits earlier in the document.
  test "a two-byte character before the selection does not shift the cut":
    # "e" with an acute accent is one code unit and two bytes.
    let r = applyBold("é hello", 2, 7)
    check r.text == "é **hello**"
    check r.selStart == 4
    check r.selEnd == 9

  test "an astral character counts as the two units the editor reports":
    # An emoji is a surrogate pair: two code units, four bytes.
    let r = applyItalic("\u{1F642} hi", 3, 5)
    check r.text == "\u{1F642} *hi*"
    check r.selStart == 4
    check r.selEnd == 6

  test "a selection that is itself non-ASCII keeps its length in units":
    let r = applyBold("say \u{1F642} now", 4, 6)
    check r.text == "say **\u{1F642}** now"
    check r.selEnd - r.selStart == 2

  test "a label taken from non-ASCII text is selected by units":
    let r = applyLink("\u{1F642} docs", 3, 7)
    check r.text == "\u{1F642} [docs](https://example.com)"
    check r.selStart == 4
    check r.selEnd == 8

  test "an offset landing inside a surrogate pair does not split it":
    # Nothing should ever send this, but a stale selection could. The offset is
    # pulled back to the character boundary rather than cutting the pair in
    # half - and the selection handed back has to be pulled back with it, or it
    # would count a half character the new text does not contain.
    let r = applyBold("\u{1F642}", 1, 1)
    check r.text == "****\u{1F642}"
    check r.selStart == 2      # between the two pairs of asterisks
    check r.selEnd == 2

  test "a selection with one end inside a surrogate pair keeps its length":
    let r = applyItalic("\u{1F642}", 1, 3)
    check r.text == "*\u{1F642}*"
    check r.selStart == 1
    check r.selEnd == 3        # the whole emoji, both its units

  test "indenting from inside a surrogate pair puts the tab before it":
    let r = applyIndent("\u{1F642}ab", 1, 1)
    check r.text == "\t\u{1F642}ab"
    check r.selStart == 1      # after the tab, before the emoji
    check r.selEnd == 1

  test "an outdented selection ending inside a pair stays inside the new text":
    let r = applyOutdent("\t\u{1F642}", 2, 2)
    check r.text == "\u{1F642}"
    check r.selStart == 0
    check r.selEnd == 0

suite "indent (Tab)":
  test "a tab goes in at the caret":
    let r = applyIndent("abc", 1, 1)
    check r.text == "a\tbc"
    check r.selStart == 2
    check r.selEnd == 2

  test "a selection inside one line is replaced, the way typing replaces it":
    let r = applyIndent("abcd", 1, 3)
    check r.text == "a\td"
    check r.selStart == 2
    check r.selEnd == 2

  test "a selection across lines indents every line it reaches":
    let r = applyIndent("a\nb\nc", 0, 3)
    check r.text == "\ta\n\tb\nc"
    # The selection still wraps the indented block, so Tab can be pressed again.
    check r.selStart == 0
    check r.selEnd == 5
    check r.text[r.selStart ..< r.selEnd] == "\ta\n\tb"

  test "a selection ending where the next line starts leaves that line alone":
    let r = applyIndent("a\nb\nc", 0, 2)
    check r.text == "\ta\nb\nc"
    check r.selStart == 0
    check r.selEnd == 3

  test "an already indented block indents one level further":
    let r = applyIndent("\ta\n\tb", 0, 5)
    check r.text == "\t\ta\n\t\tb"

  test "indenting is counted in units, not bytes":
    let r = applyIndent("\u{1F642}\nb", 0, 4)
    check r.text == "\t\u{1F642}\n\tb"
    check r.selStart == 0
    check r.selEnd == 6

  test "out-of-range offsets are clamped":
    let r = applyIndent("hi", -4, 999)
    check r.text == "\t"

suite "outdent (Shift+Tab)":
  test "a leading tab comes off the caret's own line":
    let r = applyOutdent("\tabc", 2, 2)
    check r.text == "abc"
    check r.selStart == 1
    check r.selEnd == 1

  test "leading spaces come off up to one tab's worth":
    check applyOutdent("    abc", 0, 0).text == "abc"
    check applyOutdent("      abc", 0, 0).text == "  abc"

  test "fewer spaces than a full level all come off":
    let r = applyOutdent("  abc", 3, 3)
    check r.text == "abc"
    check r.selStart == 1

  test "a line that is not indented is left exactly as it is":
    let r = applyOutdent("abc", 1, 1)
    check r.text == "abc"
    check r.selStart == 1

  test "only the indented lines of a selected block lose anything":
    let r = applyOutdent("\ta\nb\n\tc", 0, 7)
    check r.text == "a\nb\nc"
    check r.selStart == 0
    check r.selEnd == 5

  test "a selection ending where the next line starts leaves that line alone":
    let r = applyOutdent("\ta\n\tb", 0, 3)
    check r.text == "a\n\tb"

  test "outdenting an empty document does nothing":
    let r = applyOutdent("", 0, 0)
    check r.text == ""
    check r.selStart == 0

suite "indenting with spaces":
  test "Tab puts in as many spaces as a level is":
    let r = applyIndent("abc", 1, 1, "  ")
    check r.text == "a  bc"
    check r.selStart == 3
    check r.selEnd == 3

  test "a selected block gets a level on every line it reaches":
    let r = applyIndent("a\nb\nc", 0, 3, "    ")
    check r.text == "    a\n    b\nc"
    check r.selStart == 0
    check r.selEnd == 11
    check r.text[r.selStart ..< r.selEnd] == "    a\n    b"

  test "spaces go in by units, not bytes":
    let r = applyIndent("\u{1F642}\nb", 0, 4, "  ")
    check r.text == "  \u{1F642}\n  b"
    check r.selStart == 0
    check r.selEnd == 8

suite "outdenting at a width":
  test "the width decides how many spaces come off":
    check applyOutdent("  abc", 0, 0, 2).text == "abc"
    check applyOutdent("    abc", 0, 0, 2).text == "  abc"
    check applyOutdent("        abc", 0, 0, 8).text == "abc"

  test "a tab is one level however wide a level is":
    check applyOutdent("\tabc", 0, 0, 2).text == "abc"
    check applyOutdent("\tabc", 0, 0, 8).text == "abc"

  test "a spaces-indented line still outdents when the width is odd":
    let r = applyOutdent("   abc", 4, 4, 3)
    check r.text == "abc"
    check r.selStart == 1

  test "an impossible width cannot eat the line":
    # The width is clamped the same way it is everywhere else, so a zero from a
    # half-typed settings box takes nothing off rather than looping.
    check applyOutdent("    abc", 0, 0, 0).text == "   abc"
    check applyOutdent("    abc", 0, 0, -5).text == "   abc"
