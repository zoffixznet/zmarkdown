## The list of recently opened files that the File menu offers.
##
## Most recently opened first, one entry per file (opening a file again moves it
## to the top rather than adding a second row), capped so the list cannot grow
## without bound. The list is persisted with the rest of the UI state, and the
## user can switch the tracking off or empty the list from Settings.
##
## Everything here is pure list arithmetic on absolute paths; deciding what
## counts as "opened" and writing the result out is the caller's business.

import std/os

const MaxRecent* = 30
  ## How many files are remembered. The menu shows the first few directly and
  ## puts the rest behind a submenu, so this is a comfortable ceiling rather
  ## than a number the user ever counts.

const MenuRecent* = 10
  ## How many are listed in the File menu itself, before "More recent files".

func addRecent*(list: openArray[string]; path: string;
                limit = MaxRecent): seq[string] =
  ## Put `path` at the top of the list, removing any earlier mention of it, and
  ## trim the result to `limit`. An empty path is ignored, and a non-positive
  ## limit yields an empty list (which is what "remember nothing" means).
  if limit <= 0: return @[]
  if path.len == 0:
    result = @[]
    for p in list:
      if result.len >= limit: break
      result.add p
    return
  result = @[path]
  for p in list:
    if result.len >= limit: break
    if p != path: result.add p

func removeRecent*(list: openArray[string]; path: string): seq[string] =
  ## Drop every mention of `path`, as if it had never been opened.
  result = @[]
  for p in list:
    if p != path: result.add p

func sanitizeRecent*(list: openArray[string]; limit = MaxRecent): seq[string] =
  ## Repair a list loaded from disk: no empties, no duplicates, no more than the
  ## cap. Order is preserved, so the most recent stays first.
  result = @[]
  if limit <= 0: return
  for p in list:
    if p.len == 0: continue
    if result.len >= limit: break
    var seen = false
    for q in result:
      if q == p:
        seen = true
        break
    if not seen: result.add p

func recentName*(path: string): string =
  ## What the menu row reads: the file's own name, with the full path kept for
  ## the tooltip. A path that ends in a separator (or is one) has no name of its
  ## own, so it falls back to the path itself rather than showing nothing.
  let name = path.extractFilename()
  if name.len > 0: name else: path
