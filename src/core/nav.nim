## Session navigation history: the chain of documents opened during this run, so
## the back and forward buttons can walk it the way a browser's do.
##
## The rules are a browser's rules. Opening a document appends it and drops
## whatever was ahead of the current position; going back and then opening
## something else therefore rewrites the tail of the chain. The same file opened
## twice is two entries, never one: "A, B, A" is a chain of three, and stepping
## back through it visits A, B, A in that order.
##
## Nothing here touches the disk. The chain lives only as long as the process,
## and holding a path in it says nothing about whether that file still exists -
## the caller reads it and decides what to do when it cannot.

const MaxNavEntries* = 200
  ## Upper bound on remembered documents. Reaching it drops the oldest, which is
  ## the one furthest back and least likely to be walked to.

type
  NavHistory* = object
    ## The chain, plus where in it we currently are.
    entries: seq[string]  ## documents in the order they were opened
    pos: int              ## index of the current document, -1 when the chain is empty

func initNavHistory*(): NavHistory =
  NavHistory(entries: @[], pos: -1)

func len*(h: NavHistory): int =
  ## Number of documents in the chain.
  h.entries.len

func position*(h: NavHistory): int =
  ## Index of the current document, or -1 when the chain is empty.
  h.pos

func chain*(h: NavHistory): seq[string] =
  ## The chain itself, oldest first. Used by the tests.
  h.entries

func current*(h: NavHistory): string =
  ## The document the chain is currently on, or "" when it is empty.
  if h.pos >= 0 and h.pos < h.entries.len: h.entries[h.pos] else: ""

func canBack*(h: NavHistory): bool =
  h.pos > 0

func canForward*(h: NavHistory): bool =
  h.pos >= 0 and h.pos < h.entries.len - 1

func backTarget*(h: NavHistory): string =
  ## The document one step back, or "" when there is none. Reading this does not
  ## move: the caller commits with `goBack` once the file has actually loaded, so
  ## a document that cannot be read leaves the chain where it was.
  if h.canBack: h.entries[h.pos - 1] else: ""

func forwardTarget*(h: NavHistory): string =
  if h.canForward: h.entries[h.pos + 1] else: ""

proc goBack*(h: var NavHistory): bool {.discardable.} =
  ## Commit a step back. False (and no movement) when there is nowhere to go.
  if not h.canBack: return false
  h.pos -= 1
  true

proc goForward*(h: var NavHistory): bool {.discardable.} =
  if not h.canForward: return false
  h.pos += 1
  true

proc push*(h: var NavHistory, path: string) =
  ## Record a newly opened document as the current one. Anything ahead of the
  ## current position is forgotten - that branch of the chain was abandoned the
  ## moment something else was opened from here.
  if path.len == 0: return
  if h.pos < h.entries.len - 1:
    h.entries.setLen(h.pos + 1)
  h.entries.add(path)
  h.pos = h.entries.len - 1
  if h.entries.len > MaxNavEntries:
    let drop = h.entries.len - MaxNavEntries
    h.entries = h.entries[drop .. ^1]
    h.pos -= drop
