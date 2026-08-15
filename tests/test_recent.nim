import std/unittest
import std/os
import "../src/core/recent"

suite "adding files":
  test "the newest file goes to the top":
    check addRecent(@[], "/a.md") == @["/a.md"]
    check addRecent(@["/a.md"], "/b.md") == @["/b.md", "/a.md"]

  test "opening a file again moves it up rather than repeating it":
    let list = @["/c.md", "/b.md", "/a.md"]
    check addRecent(list, "/a.md") == @["/a.md", "/c.md", "/b.md"]
    check addRecent(list, "/c.md") == list

  test "an empty path adds nothing but still trims":
    check addRecent(@["/a.md", "/b.md"], "") == @["/a.md", "/b.md"]
    check addRecent(@["/a.md", "/b.md"], "", limit = 1) == @["/a.md"]

  test "the list is capped, oldest dropped":
    var list: seq[string]
    for i in 1 .. MaxRecent + 5:
      list = addRecent(list, "/f" & $i & ".md")
    check list.len == MaxRecent
    check list[0] == "/f" & $(MaxRecent + 5) & ".md"
    check "/f1.md" notin list

  test "a limit of zero remembers nothing":
    check addRecent(@["/a.md"], "/b.md", limit = 0).len == 0

suite "forgetting files":
  test "removing takes out every mention":
    check removeRecent(@["/a.md", "/b.md", "/a.md"], "/a.md") == @["/b.md"]

  test "removing something that is not there changes nothing":
    check removeRecent(@["/a.md"], "/zz.md") == @["/a.md"]

  test "removing from an empty list is fine":
    check removeRecent(@[], "/a.md").len == 0

suite "repairing a list loaded from disk":
  test "empties and duplicates are dropped, order kept":
    check sanitizeRecent(@["/a.md", "", "/b.md", "/a.md", ""]) ==
      @["/a.md", "/b.md"]

  test "an over-long stored list is trimmed":
    var list: seq[string]
    for i in 1 .. MaxRecent + 10:
      list.add("/f" & $i & ".md")
    check sanitizeRecent(list).len == MaxRecent
    check sanitizeRecent(list)[0] == "/f1.md"  # newest-first order is preserved

  test "an empty list stays empty":
    check sanitizeRecent(@[]).len == 0

suite "what the menu shows":
  test "a row reads as the file's own name":
    check recentName("/home/me/notes/plan.md") == "plan.md"
    check recentName("plan.md") == "plan.md"

  test "a path with no file name of its own falls back to itself":
    check recentName("/home/me/notes" & DirSep) == "/home/me/notes" & DirSep
    check recentName("") == ""

  test "the menu shows fewer files than are remembered":
    # Otherwise "More recent files" would never have anything behind it.
    check MenuRecent < MaxRecent
