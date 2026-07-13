import std/unittest
import std/strutils
import std/options
import "../src/core/history"

suite "undo/redo history":

  test "basic record, undo, redo round trip":
    var h = initHistory()
    h.reset("")
    h.record("a", 1, 1)
    h.record("ab", 2, 2)
    check h.canUndo
    check not h.canRedo
    let u1 = h.undo()
    check u1.isSome
    check u1.get().text == "a"
    check u1.get().selStart == 1
    let u2 = h.undo()
    check u2.isSome
    check u2.get().text == ""
    check not h.canUndo
    let r1 = h.redo()
    check r1.isSome
    check r1.get().text == "a"

  test "undo on empty history returns none":
    var h = initHistory()
    h.reset("hello")
    check not h.canUndo
    check h.undo().isNone
    check h.redo().isNone

  test "a new edit clears the redo stack":
    var h = initHistory()
    h.reset("")
    h.record("one")
    h.record("two")
    discard h.undo()          # back to "one"
    check h.canRedo
    h.record("three")         # new edit
    check not h.canRedo
    check h.redo().isNone

  test "recording the same text is a selection move, not an undo step":
    var h = initHistory()
    h.reset("same")
    h.record("same", 4, 4)    # only the caret moved
    check not h.canUndo

  test "no step limit: thousands of edits are all undoable within the byte cap":
    var h = initHistory()     # default 100 MB cap
    h.reset("")
    for i in 1 .. 3000:
      h.record($i)
    # Every one of the 3000 edits is retained; undo walks all the way back.
    var steps = 0
    while h.canUndo:
      discard h.undo()
      inc steps
    check steps == 3000

  test "byte cap evicts the oldest snapshots":
    # Cap at 100 bytes; each snapshot is 40 bytes of text.
    var h = initHistory(maxBytes = 100)
    h.reset("a".repeat(40))
    h.record("b".repeat(40))  # bytes now 80, fits
    h.record("c".repeat(40))  # bytes 120 > 100, oldest ("a") evicted
    check h.bytesUsed == 80
    let u1 = h.undo()         # back to "b"
    check u1.isSome
    check u1.get().text == "b".repeat(40)
    check not h.canUndo       # "a" is gone, cannot undo further

  test "the current state is never dropped even if larger than the cap":
    var h = initHistory(maxBytes = 10)
    h.reset("x".repeat(50))   # single snapshot bigger than the whole cap
    check h.bytesUsed == 50   # kept, not dropped, no crash
    check not h.canUndo
    h.record("y".repeat(50))  # recording another oversized state does not crash
    check h.bytesUsed == 50   # only the current survives; the prior step is evicted
    check not h.canUndo       # no undo history is retained when one state alone exceeds the cap

  test "reset clears everything":
    var h = initHistory()
    h.reset("")
    h.record("a")
    h.record("b")
    h.reset("fresh")
    check not h.canUndo
    check not h.canRedo
