import std/unittest
import std/options
import "../src/core/indent"

suite "what a document indents with":
  test "a leading tab anywhere settles it":
    check detectIndent("a\n\tb\n") == some(ikTab)
    check detectIndent("\tonly line") == some(ikTab)

  test "spaces lined up before a tab are still a tab":
    check detectIndent("a\n  \tb\n") == some(ikTab)

  test "one tab outweighs any amount of spaces":
    # "if we see some tabs, use tabs" - whichever came first in the file.
    check detectIndent("    a\n\tb\n") == some(ikTab)
    check detectIndent("\ta\n    b\n") == some(ikTab)

  test "two or more leading spaces mean spaces":
    check detectIndent("a\n    b\n") == some(ikSpace)
    check detectIndent("a\n  b\n") == some(ikSpace)

  test "a single leading space is a typo, not indentation":
    check detectIndent("a\n b\n").isNone

  test "a line of nothing but whitespace is a blank line":
    check detectIndent("a\n    \nb\n").isNone
    check detectIndent("a\n    \r\nb\n").isNone

  test "a document with no indentation says nothing":
    check detectIndent("").isNone
    check detectIndent("plain\nlines\nonly\n").isNone

  test "the last line counts even without a newline after it":
    check detectIndent("a\n\tb") == some(ikTab)
    check detectIndent("a\n    b") == some(ikSpace)

suite "settling on a style for a document":
  test "an explicit preference ignores the document":
    check resolveIndent(ipTab, "    spaces here\n") == ikTab
    check resolveIndent(ipSpace, "\ttabs here\n") == ikSpace

  test "auto follows the document":
    check resolveIndent(ipAuto, "a\n\tb\n") == ikTab
    check resolveIndent(ipAuto, "a\n    b\n") == ikSpace

  test "auto falls back to a tab when the document gives no clue":
    # What the key itself means, and what the editor did before this was a
    # setting at all.
    check resolveIndent(ipAuto, "") == ikTab
    check resolveIndent(ipAuto, "no indentation at all\n") == ikTab

suite "one level of indentation":
  test "a tab is a tab whatever the width":
    check indentUnit(ikTab, 2) == "\t"
    check indentUnit(ikTab, 8) == "\t"

  test "spaces are as many as the width asks for":
    check indentUnit(ikSpace, 4) == "    "
    check indentUnit(ikSpace, 2) == "  "

  test "an impossible width cannot produce impossible indentation":
    check indentUnit(ikSpace, 0) == " "
    check indentUnit(ikSpace, -3) == " "
    check indentUnit(ikSpace, 999).len == MaxTabWidth

suite "widths":
  test "the range is held":
    check clampTabWidth(4) == 4
    check clampTabWidth(0) == MinTabWidth
    check clampTabWidth(-1) == MinTabWidth
    check clampTabWidth(1000) == MaxTabWidth
    check clampTabWidth(MaxTabWidth) == MaxTabWidth

  test "the default is four":
    check DefaultTabWidth == 4
    check clampTabWidth(DefaultTabWidth) == DefaultTabWidth

suite "names that go to disk and back":
  test "every preference survives its persisted name":
    for p in [ipAuto, ipTab, ipSpace]:
      check parseIndentPref($p) == some(p)

  test "every style survives its persisted name":
    for k in [ikTab, ikSpace]:
      check parseIndentKind($k) == some(k)

  test "anything else is not guessed at":
    check parseIndentPref("").isNone
    check parseIndentPref("Tabs").isNone
    check parseIndentPref("spaces").isNone
    # "auto" is a preference, never a style: by the time something is being
    # inserted the question has been answered.
    check parseIndentKind("auto").isNone

  test "auto is the default preference":
    check DefaultIndentPref == ipAuto

suite "whitespace that indents nothing":
  # A stray tab on an otherwise blank line is debris, not a statement about how
  # the document is indented - the same rule the space side has always applied.
  test "a blank line made of a tab does not make it a tab document":
    check detectIndent("para\n    item\n\t\n    item2\n") == some(ikSpace)
    check detectIndent("a\r\n\t\r\nb\r\n").isNone

  test "a file ending in a whitespace-only line says nothing":
    check detectIndent("abc\n\t").isNone
    check detectIndent("abc\n    ").isNone
    check detectIndent("\t").isNone
    check detectIndent("   \n \t \n").isNone

  test "a real indented line still counts, tab or space":
    check detectIndent("a\n\t \nb\n\tc\n") == some(ikTab)
    check detectIndent("a\n \t\nb\n  c\n") == some(ikSpace)
