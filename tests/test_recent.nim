import std/unittest
import std/os
import std/options
import "../src/core/recent"

func f(path: string): RecentFile = recentFile(path)
func f(path: string, view: ViewMode): RecentFile = recentFile(path, some(view))

suite "adding files":
  test "the newest file goes to the top":
    check addRecent(@[], "/a.md") == @[f"/a.md"]
    check addRecent(@[f"/a.md"], "/b.md") == @[f"/b.md", f"/a.md"]

  test "opening a file again moves it up rather than repeating it":
    let list = @[f"/c.md", f"/b.md", f"/a.md"]
    check addRecent(list, "/a.md") == @[f"/a.md", f"/c.md", f"/b.md"]
    check addRecent(list, "/c.md") == list

  test "an empty path adds nothing but still trims":
    check addRecent(@[f"/a.md", f"/b.md"], "") == @[f"/a.md", f"/b.md"]
    check addRecent(@[f"/a.md", f"/b.md"], "", limit = 1) == @[f"/a.md"]

  test "the list is capped, oldest dropped":
    var list: seq[RecentFile]
    for i in 1 .. MaxRecent + 5:
      list = addRecent(list, "/f" & $i & ".md")
    check list.len == MaxRecent
    check list[0].path == "/f" & $(MaxRecent + 5) & ".md"
    check "/f1.md" notin list.paths

  test "a limit of zero remembers nothing":
    check addRecent(@[f"/a.md"], "/b.md", limit = 0).len == 0

suite "the view a file was last read in":
  test "opening a file records the view it opened in":
    let list = addRecent(@[], "/a.md", some(vmPreview))
    check list == @[f("/a.md", vmPreview)]
    check recentView(list, "/a.md") == some(vmPreview)

  test "reopening in another view replaces the recorded one":
    let list = addRecent(@[f("/a.md", vmPreview)], "/a.md", some(vmText))
    check recentView(list, "/a.md") == some(vmText)

  test "adding without a view keeps what was already known":
    # The view argument is optional, and leaving it out has to mean "I have
    # nothing to say about the view" rather than "forget what you knew".
    let list = addRecent(@[f("/a.md", vmText)], "/a.md")
    check recentView(list, "/a.md") == some(vmText)

  test "a file nothing is remembered about has no view":
    check recentView(@[f("/a.md", vmText)], "/b.md").isNone
    check recentView(@[], "/a.md").isNone
    check recentView(@[f"/a.md"], "/a.md").isNone
    check recentView(@[f("/a.md", vmText)], "").isNone

  test "noting a view leaves the order of the list alone":
    let list = @[f"/c.md", f("/b.md", vmText), f"/a.md"]
    let after = noteRecentView(list, "/a.md", vmSplit)
    check after.paths == @["/c.md", "/b.md", "/a.md"]
    check recentView(after, "/a.md") == some(vmSplit)
    check recentView(after, "/b.md") == some(vmText)

  test "noting a view for a file that is not remembered adds nothing":
    let list = @[f"/a.md"]
    check noteRecentView(list, "/zz.md", vmText) == list
    check noteRecentView(@[], "/a.md", vmText).len == 0

  test "an empty path notes nothing, even against an empty entry":
    check noteRecentView(@[f""], "", vmText) == @[f""]

suite "forgetting files":
  test "removing takes out every mention":
    check removeRecent(@[f"/a.md", f"/b.md", f("/a.md", vmText)], "/a.md") ==
      @[f"/b.md"]

  test "removing something that is not there changes nothing":
    check removeRecent(@[f"/a.md"], "/zz.md") == @[f"/a.md"]

  test "removing from an empty list is fine":
    check removeRecent(@[], "/a.md").len == 0

suite "repairing a list loaded from disk":
  test "empties and duplicates are dropped, order kept":
    check sanitizeRecent(@[f"/a.md", f"", f"/b.md", f"/a.md", f""]) ==
      @[f"/a.md", f"/b.md"]

  test "a duplicate keeps the view of the most recent mention":
    check sanitizeRecent(@[f("/a.md", vmText), f("/a.md", vmPreview)]) ==
      @[f("/a.md", vmText)]

  test "an over-long stored list is trimmed":
    var list: seq[RecentFile]
    for i in 1 .. MaxRecent + 10:
      list.add(f("/f" & $i & ".md"))
    check sanitizeRecent(list).len == MaxRecent
    check sanitizeRecent(list)[0].path == "/f1.md"  # newest-first order is preserved

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

suite "view mode names":
  test "every view mode survives its persisted name":
    for v in [vmText, vmSplit, vmPreview]:
      check parseViewMode($v) == some(v)

  test "anything that is not a view mode is not guessed at":
    check parseViewMode("").isNone
    check parseViewMode("Text").isNone
    check parseViewMode("reading").isNone

suite "the view a document opens in":
  test "a remembered view wins, whatever is in the document":
    check openingView(some(vmPreview), blank = true, remembering = true,
                      lastChosen = vmSplit) == vmPreview
    check openingView(some(vmText), blank = false, remembering = true,
                      lastChosen = vmSplit) == vmText

  test "an empty document opens in Text, to be written in":
    check openingView(none(ViewMode), blank = true, remembering = true,
                      lastChosen = vmSplit) == vmText
    # Emptiness is a property of the document, not of what is remembered, so
    # this holds with the remembering switched off too.
    check openingView(none(ViewMode), blank = true, remembering = false,
                      lastChosen = vmSplit) == vmText

  test "an unfamiliar document with something in it opens in Preview":
    check openingView(none(ViewMode), blank = false, remembering = true,
                      lastChosen = vmText) == vmPreview

  test "with nothing remembered at all, the last hand pick decides":
    check openingView(none(ViewMode), blank = false, remembering = false,
                      lastChosen = vmText) == vmText
    check openingView(none(ViewMode), blank = false, remembering = false,
                      lastChosen = vmSplit) == vmSplit
