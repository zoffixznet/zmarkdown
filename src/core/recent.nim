## The list of recently opened files that the File menu offers.
##
## Most recently opened first, one entry per file (opening a file again moves it
## to the top rather than adding a second row), capped so the list cannot grow
## without bound. The list is persisted with the rest of the UI state, and the
## user can switch the tracking off or empty the list from Settings.
##
## Each entry also carries the view the file was last looked at in, which is
## what lets a file reopen the way you left it: read a README in Preview and it
## comes back in Preview, edit one in Text and it comes back in Text. The view
## is optional, because an entry can predate the app remembering views at all -
## and "we have no idea" has to stay tellable from "it was Split", or every old
## entry would claim a view the user never chose.
##
## Everything here is pure list arithmetic on absolute paths; deciding what
## counts as "opened" and writing the result out is the caller's business.

import std/os
import std/options

import viewmode
export viewmode

const MaxRecent* = 30
  ## How many files are remembered. The menu shows the first few directly and
  ## puts the rest behind a submenu, so this is a comfortable ceiling rather
  ## than a number the user ever counts.

const MenuRecent* = 10
  ## How many are listed in the File menu itself, before "More recent files".

type
  RecentFile* = object
    ## One remembered file: where it is, and the view it was last in.
    path*: string
    view*: Option[ViewMode]  ## `none` when nothing was ever recorded for it

func recentFile*(path: string; view = none(ViewMode)): RecentFile =
  ## An entry, spelled out in one place so the tests and the callers agree on
  ## what a bare path with no remembered view looks like.
  RecentFile(path: path, view: view)

func paths*(list: openArray[RecentFile]): seq[string] =
  ## Just the paths, in order. Convenient where only the files matter.
  result = @[]
  for f in list: result.add f.path

func addRecent*(list: openArray[RecentFile]; path: string;
                view = none(ViewMode); limit = MaxRecent): seq[RecentFile] =
  ## Put `path` at the top of the list, removing any earlier mention of it, and
  ## trim the result to `limit`. An empty path is ignored, and a non-positive
  ## limit yields an empty list (which is what "remember nothing" means).
  ##
  ## `view` is what the file is being opened in. Passing `none` keeps whatever
  ## view the earlier entry for this file carried, so a caller that has nothing
  ## to say about the view cannot erase what was known.
  if limit <= 0: return @[]
  if path.len == 0:
    result = @[]
    for f in list:
      if result.len >= limit: break
      result.add f
    return
  var kept = view
  if kept.isNone:
    for f in list:
      if f.path == path:
        kept = f.view
        break
  result = @[recentFile(path, kept)]
  for f in list:
    if result.len >= limit: break
    if f.path != path: result.add f

func removeRecent*(list: openArray[RecentFile]; path: string): seq[RecentFile] =
  ## Drop every mention of `path`, as if it had never been opened.
  result = @[]
  for f in list:
    if f.path != path: result.add f

func recentView*(list: openArray[RecentFile]; path: string): Option[ViewMode] =
  ## The view this file was last looked at in, or `none` when the file is not
  ## remembered or its entry never recorded one.
  if path.len == 0: return none(ViewMode)
  for f in list:
    if f.path == path: return f.view
  none(ViewMode)

func noteRecentView*(list: openArray[RecentFile]; path: string;
                     view: ViewMode): seq[RecentFile] =
  ## Record the view a remembered file is now being read in, leaving the order
  ## of the list alone: switching to Preview half way through reading something
  ## is not a reason for it to jump to the top of "recently opened".
  ##
  ## A file that is not in the list is not added by this. One is only there
  ## because it was opened, and a file the user told the app to forget must not
  ## creep back in on a view switch.
  result = @[]
  for f in list:
    if f.path == path and path.len > 0: result.add recentFile(f.path, some(view))
    else: result.add f

func sanitizeRecent*(list: openArray[RecentFile];
                     limit = MaxRecent): seq[RecentFile] =
  ## Repair a list loaded from disk: no empties, no duplicates, no more than the
  ## cap. Order is preserved, so the most recent stays first, and a duplicate
  ## keeps the view of the first (most recent) mention of the file.
  result = @[]
  if limit <= 0: return
  for f in list:
    if f.path.len == 0: continue
    if result.len >= limit: break
    var seen = false
    for g in result:
      if g.path == f.path:
        seen = true
        break
    if not seen: result.add f

func recentName*(path: string): string =
  ## What the menu row reads: the file's own name, with the full path kept for
  ## the tooltip. A path that ends in a separator (or is one) has no name of its
  ## own, so it falls back to the path itself rather than showing nothing.
  let name = path.extractFilename()
  if name.len > 0: name else: path
