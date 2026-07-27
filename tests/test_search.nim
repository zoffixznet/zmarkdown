import std/unittest
import "../src/core/search"

const
  plain = SearchOpts(matchCase: false, wholeWord: false)
  cased = SearchOpts(matchCase: true, wholeWord: false)
  word = SearchOpts(matchCase: false, wholeWord: true)
  casedWord = SearchOpts(matchCase: true, wholeWord: true)

suite "find":
  test "finds every occurrence in document order":
    let r = find("one two one two one", "one", plain)
    check r.total == 3
    check r.matches.len == 3
    check r.matches[0] == Match(start: 0, stop: 3)
    check r.matches[1] == Match(start: 8, stop: 11)
    check r.matches[2] == Match(start: 16, stop: 19)

  test "is case-insensitive by default":
    let r = find("Renderer renderer RENDERER", "renderer", plain)
    check r.total == 3

  test "match case distinguishes case":
    let r = find("Renderer renderer RENDERER", "renderer", cased)
    check r.total == 1
    check r.matches[0].start == 9

  test "an empty needle matches nothing":
    # Otherwise an empty find box would select the whole document.
    let r = find("some text", "", plain)
    check r.total == 0
    check r.matches.len == 0

  test "a needle longer than the text matches nothing":
    check find("hi", "hello", plain).total == 0

  test "no match in an empty document":
    check find("", "x", plain).total == 0

  test "matches do not overlap":
    # "aa" in "aaaa" is two matches, not three: scanning resumes after a hit.
    let r = find("aaaa", "aa", plain)
    check r.total == 2
    check r.matches[0] == Match(start: 0, stop: 2)
    check r.matches[1] == Match(start: 2, stop: 4)

  test "a match at the very end is found":
    let r = find("abc", "c", plain)
    check r.matches == @[Match(start: 2, stop: 3)]

  test "newlines are ordinary characters":
    let r = find("a\nb\na", "a", plain)
    check r.total == 2
    check r.matches[1] == Match(start: 4, stop: 5)

  test "the limit caps the returned matches but not the count":
    let r = find("x x x x x", "x", plain, limit = 2)
    check r.total == 5      # honest total
    check r.matches.len == 2
    check r.capped

  test "an uncapped search is not reported as capped":
    let r = find("x x x", "x", plain)
    check r.total == 3
    check not r.capped

  test "limit = 0 means no cap at all":
    let r = find("x x x x x", "x", plain, limit = 0)
    check r.total == 5
    check r.matches.len == 5
    check not r.capped

suite "whole word":
  test "skips matches glued to word characters":
    let r = find("is this his? is", "is", word)
    # "is" alone at 0 and at 13; the "is" inside "this" and "his" are skipped.
    check r.total == 2
    check r.matches[0] == Match(start: 0, stop: 2)
    check r.matches[1] == Match(start: 13, stop: 15)

  test "punctuation and whitespace are word boundaries":
    check find("(cat) cat, cat.", "cat", word).total == 3

  test "underscores and digits are word characters":
    check find("cat_1 cat2 cat", "cat", word).total == 1

  test "non-ASCII letters are word characters":
    # "naïve" must not match inside "naïveté".
    check find("naïveté naïve", "naïve", word).total == 1

  test "combines with match case":
    check find("Cat cat CAT", "cat", casedWord).total == 1

suite "UTF-16 offsets":
  # The editor reports and expects UTF-16 code unit offsets. These are the cases
  # where byte offsets would disagree and put the caret in the wrong place.
  test "two-byte characters count as one code unit":
    # "é" is 2 UTF-8 bytes but 1 UTF-16 unit.
    let r = find("café bar", "bar", plain)
    check r.matches == @[Match(start: 5, stop: 8)]

  test "astral characters count as two code units":
    # "🙂" is 4 UTF-8 bytes and a surrogate pair: 2 UTF-16 units.
    let r = find("🙂 tail", "tail", plain)
    check r.matches == @[Match(start: 3, stop: 7)]

  test "a non-ASCII needle reports its own span":
    let r = find("x 🙂 y", "🙂", plain)
    check r.matches == @[Match(start: 2, stop: 4)]

  test "case folding works beyond ASCII":
    check find("ÉCOLE école", "école", plain).total == 2
    check find("ÉCOLE école", "école", cased).total == 1

  test "mixed-width text keeps every offset aligned":
    let r = find("é🙂é hit é", "hit", plain)
    # é(1) + 🙂(2) + é(1) + space(1) = 5
    check r.matches == @[Match(start: 5, stop: 8)]

suite "replaceAll":
  test "replaces every match and reports the count":
    let r = replaceAll("one two one", "one", "1", plain)
    check r.text == "1 two 1"
    check r.replaced == 2

  test "leaves the text alone when there is no match":
    let r = replaceAll("hello", "zzz", "x", plain)
    check r.text == "hello"
    check r.replaced == 0

  test "an empty needle changes nothing":
    let r = replaceAll("hello", "", "x", plain)
    check r.text == "hello"
    check r.replaced == 0

  test "replacing with the empty string deletes the matches":
    let r = replaceAll("a-b-c", "-", "", plain)
    check r.text == "abc"
    check r.replaced == 2

  test "a replacement containing the needle is not re-scanned":
    # Every match is located in the original text and spliced in one pass, so
    # this terminates with one doubling rather than growing without bound.
    let r = replaceAll("aaa", "a", "aa", plain)
    check r.text == "aaaaaa"
    check r.replaced == 3

  test "honors match case":
    let r = replaceAll("Cat cat", "cat", "dog", cased)
    check r.text == "Cat dog"
    check r.replaced == 1

  test "honors whole word":
    let r = replaceAll("cat category cat", "cat", "dog", word)
    check r.text == "dog category dog"
    check r.replaced == 2

  test "the caret lands after the last replacement":
    let r = replaceAll("one two one", "one", "1", plain)
    check r.text == "1 two 1"
    # "1 two " is 6 units, plus the 1-unit replacement.
    check r.selStart == 7
    check r.selEnd == 7

  test "the caret is correct when the replacement is longer":
    let r = replaceAll("a a", "a", "xyz", plain)
    check r.text == "xyz xyz"
    check r.selStart == 7
    check r.selEnd == 7

  test "the caret is correct when the replacement is shorter":
    let r = replaceAll("aaa aaa", "aaa", "b", plain)
    check r.text == "b b"
    check r.selStart == 3

  test "the caret is measured in UTF-16 units":
    let r = replaceAll("🙂 x", "x", "y", plain)
    check r.text == "🙂 y"
    check r.selStart == 4   # 🙂(2) + space(1) + y(1)

  test "non-ASCII replacement text survives intact":
    let r = replaceAll("cafe bar", "cafe", "café", plain)
    check r.text == "café bar"
    check r.replaced == 1

suite "replaceOne":
  test "replaces the match the selection covers":
    let r = replaceOne("one two one", "one", "1", plain, 0, 3)
    check r.text == "1 two one"
    check r.replaced == 1
    check r.selStart == 1   # caret after the inserted text
    check r.selEnd == 1

  test "replaces a later match when that is the selected one":
    let r = replaceOne("one two one", "one", "1", plain, 8, 11)
    check r.text == "one two 1"
    check r.replaced == 1
    check r.selStart == 9

  test "does nothing when the selection is not a match":
    let r = replaceOne("one two one", "one", "1", plain, 4, 7)
    check r.text == "one two one"
    check r.replaced == 0
    check r.selStart == 4   # selection preserved
    check r.selEnd == 7

  test "does nothing when the selection only partly covers a match":
    let r = replaceOne("one two", "one", "1", plain, 0, 2)
    check r.replaced == 0
    check r.text == "one two"

  test "does nothing with an empty selection":
    let r = replaceOne("one two", "one", "1", plain, 0, 0)
    check r.replaced == 0

  test "a reversed selection is normalized":
    let r = replaceOne("one two", "one", "1", plain, 3, 0)
    check r.text == "1 two"
    check r.replaced == 1

  test "respects match case":
    let r = replaceOne("Cat", "cat", "dog", cased, 0, 3)
    check r.replaced == 0
    check r.text == "Cat"

  test "respects whole word":
    let r = replaceOne("category", "cat", "dog", word, 0, 3)
    check r.replaced == 0
    check r.text == "category"

  test "works at UTF-16 offsets past a surrogate pair":
    let r = replaceOne("🙂 cat", "cat", "dog", plain, 3, 6)
    check r.text == "🙂 dog"
    check r.replaced == 1
    check r.selStart == 6

  test "a selection landing inside a surrogate pair is rejected":
    # Offset 1 is the middle of the pair: no rune starts there.
    let r = replaceOne("🙂🙂", "🙂", "x", plain, 1, 3)
    check r.replaced == 0

suite "bounds safety":
  test "out-of-range selection offsets do not crash replaceOne":
    let r = replaceOne("hi", "hi", "yo", plain, -5, 999)
    check r.replaced == 0
    check r.text == "hi"

  test "a huge needle against a tiny document is fine":
    check find("a", "aaaaaaaaaaaaaaaa", plain).total == 0
