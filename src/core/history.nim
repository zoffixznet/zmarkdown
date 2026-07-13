## Bounded in-memory undo/redo history.
##
## Snapshots are full copies of the editor text plus its selection, held in a
## growable deque. Nothing is pre-allocated: the deque starts empty and grows as
## edits are recorded. There is no limit on the number of steps. The only bound
## is total memory: once the retained snapshots exceed the byte cap (default
## 100 MB), the OLDEST snapshots are dropped until the total is back under the
## cap. The current on-screen state is never dropped, even if it alone is larger
## than the cap. This module is pure and is unit-tested without any GUI.

import std/[deques, options]

type
  Snapshot* = object
    text*: string
    selStart*, selEnd*: int

  History* = object
    past: Deque[Snapshot]     ## undo stack, oldest at the front
    future: Deque[Snapshot]   ## redo stack, most recently undone at the back
    cur: Snapshot             ## the live, on-screen state
    hasCur: bool
    bytes: int                ## running sum of text bytes across past+future+cur
    maxBytes: int             ## cap on total retained snapshot bytes

const
  DefaultMaxBytes* = 100 * 1024 * 1024  ## 100 MB

func initHistory*(maxBytes = DefaultMaxBytes): History =
  ## A fresh, empty history. No memory is reserved up front.
  History(
    past: initDeque[Snapshot](),
    future: initDeque[Snapshot](),
    hasCur: false,
    bytes: 0,
    maxBytes: max(0, maxBytes),
  )

func canUndo*(h: History): bool = h.past.len > 0
func canRedo*(h: History): bool = h.future.len > 0
func bytesUsed*(h: History): int = h.bytes

proc evict(h: var History) =
  ## Drop the oldest undo snapshots until back under the byte cap. Only the undo
  ## stack is trimmed; the current state and pending redo are kept. If the undo
  ## stack is empty the cap may still be exceeded (a single snapshot larger than
  ## the cap): we never discard the state currently shown.
  while h.bytes > h.maxBytes and h.past.len > 0:
    let s = h.past.popFirst()
    h.bytes -= s.text.len

proc reset*(h: var History; text: string; selStart = 0; selEnd = 0) =
  ## Clear all history and start over from `text` as the current state. Used at
  ## startup and whenever a different document is loaded, so undo never crosses
  ## from one file back into another.
  h.past.clear()
  h.future.clear()
  h.cur = Snapshot(text: text, selStart: selStart, selEnd: selEnd)
  h.hasCur = true
  h.bytes = text.len

proc record*(h: var History; text: string; selStart = 0; selEnd = 0) =
  ## Commit `text` as the new current state. The previous current becomes an undo
  ## point and the redo stack is cleared. A record whose text equals the current
  ## text only updates the stored selection (a selection move is not an undo
  ## step). Oldest steps are evicted if the byte cap is exceeded.
  if not h.hasCur:
    h.reset(text, selStart, selEnd)
    return
  if text == h.cur.text:
    h.cur.selStart = selStart
    h.cur.selEnd = selEnd
    return
  # A new edit invalidates any redo history.
  while h.future.len > 0:
    let s = h.future.popLast()
    h.bytes -= s.text.len
  h.past.addLast(h.cur)                 # old current is already counted in bytes
  h.cur = Snapshot(text: text, selStart: selStart, selEnd: selEnd)
  h.bytes += text.len
  h.evict()

proc undo*(h: var History): Option[Snapshot] =
  ## Move one step back. Returns the snapshot to show, or none if there is
  ## nothing to undo. Does not change the byte total (snapshots move between
  ## stacks, they are not dropped).
  if h.past.len == 0:
    return none(Snapshot)
  h.future.addLast(h.cur)
  h.cur = h.past.popLast()
  h.hasCur = true
  some(h.cur)

proc redo*(h: var History): Option[Snapshot] =
  ## Move one step forward. Returns the snapshot to show, or none if there is
  ## nothing to redo.
  if h.future.len == 0:
    return none(Snapshot)
  h.past.addLast(h.cur)
  h.cur = h.future.popLast()
  h.hasCur = true
  some(h.cur)
