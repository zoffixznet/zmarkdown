import std/unittest
import "../src/core/nav"

suite "an empty chain":
  test "nothing to go back or forward to":
    let h = initNavHistory()
    check h.len == 0
    check h.position == -1
    check h.current == ""
    check not h.canBack
    check not h.canForward
    check h.backTarget() == ""
    check h.forwardTarget() == ""

  test "stepping an empty chain does nothing":
    var h = initNavHistory()
    check not h.goBack()
    check not h.goForward()
    check h.position == -1

suite "opening documents":
  test "the first document has nowhere to go":
    var h = initNavHistory()
    h.push("/a.md")
    check h.current == "/a.md"
    check not h.canBack
    check not h.canForward

  test "a second document makes back available":
    var h = initNavHistory()
    h.push("/a.md")
    h.push("/b.md")
    check h.current == "/b.md"
    check h.canBack
    check not h.canForward
    check h.backTarget() == "/a.md"

  test "an empty path is not a document":
    var h = initNavHistory()
    h.push("")
    check h.len == 0

  test "the same file opened again is a separate entry":
    # A, B, A is a chain of three: back from the second A goes to B, not to
    # nowhere. The buttons walk where you have been, not which files you own.
    var h = initNavHistory()
    h.push("/a.md")
    h.push("/b.md")
    h.push("/a.md")
    check h.len == 3
    check h.chain == @["/a.md", "/b.md", "/a.md"]
    check h.backTarget() == "/b.md"
    h.goBack()
    check h.current == "/b.md"
    h.goBack()
    check h.current == "/a.md"
    check not h.canBack

suite "walking the chain":
  setup:
    var h = initNavHistory()
    h.push("/a.md")
    h.push("/b.md")
    h.push("/c.md")

  test "back walks to the start and stops there":
    check h.current == "/c.md"
    check h.goBack()
    check h.current == "/b.md"
    check h.goBack()
    check h.current == "/a.md"
    check not h.canBack
    check not h.goBack()
    check h.current == "/a.md"

  test "forward walks to the end and stops there":
    h.goBack()
    h.goBack()
    check h.canForward
    check h.goForward()
    check h.current == "/b.md"
    check h.goForward()
    check h.current == "/c.md"
    check not h.canForward
    check not h.goForward()

  test "reading a target does not move":
    check h.backTarget() == "/b.md"
    check h.backTarget() == "/b.md"
    check h.current == "/c.md"

suite "opening from part-way back rewrites the tail":
  test "everything ahead of the current position is forgotten":
    # Open A, B, C; walk all the way back to A; open D. B and C were on a branch
    # that was abandoned, so the chain is A, D and nothing else.
    var h = initNavHistory()
    h.push("/a.md")
    h.push("/b.md")
    h.push("/c.md")
    h.goBack()
    h.goBack()
    check h.current == "/a.md"
    h.push("/d.md")
    check h.chain == @["/a.md", "/d.md"]
    check h.current == "/d.md"
    check h.canBack
    check not h.canForward
    h.goBack()
    check h.current == "/a.md"

  test "opening from the middle keeps only what is behind it":
    var h = initNavHistory()
    for p in ["/a.md", "/b.md", "/c.md", "/d.md"]:
      h.push(p)
    h.goBack()  # on C
    h.push("/e.md")
    check h.chain == @["/a.md", "/b.md", "/c.md", "/e.md"]

suite "the chain is bounded":
  test "the oldest entries fall off once the cap is reached":
    var h = initNavHistory()
    for i in 0 .. MaxNavEntries + 4:
      h.push("/f" & $i & ".md")
    check h.len == MaxNavEntries
    check h.current == "/f" & $(MaxNavEntries + 4) & ".md"
    check h.position == MaxNavEntries - 1
    # The oldest survivor is still reachable, and back stops there.
    for _ in 1 ..< MaxNavEntries: h.goBack()
    check h.current == "/f5.md"
    check not h.canBack
