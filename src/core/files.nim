## File read/write with error handling. Every predictable IO failure is turned
## into a Result the caller can act on (show a dialog, keep the document), never
## an exception that takes down the app.

import std/[os, times]

type
  FileStamp* = object
    ## What a file looked like the last time the app read or wrote it, so that a
    ## change made by something else can be noticed before it is overwritten.
    exists*: bool
    size*: int64
    mtime*: Time

  IoOutcome*[T] = object
    ## Success carries a value; failure carries a human-readable message.
    ok*: bool
    value*: T
    error*: string

func ioOk*[T](value: T): IoOutcome[T] =
  IoOutcome[T](ok: true, value: value)

func ioErr*[T](msg: string): IoOutcome[T] =
  IoOutcome[T](ok: false, error: msg)

proc readTextFile*(path: string): IoOutcome[string] =
  ## Read a whole file as text. On any error returns a failure outcome with a
  ## message suitable for an error dialog.
  try:
    ioOk(readFile(path))
  except IOError as e:
    ioErr[string]("Could not read file: " & e.msg)
  except OSError as e:
    ioErr[string]("Could not read file: " & e.msg)
  except CatchableError as e:
    ioErr[string]("Could not read file: " & e.msg)

proc writeTextFile*(path, content: string): IoOutcome[bool] =
  ## Write text to a file, replacing any existing contents. Missing parent
  ## directories are created first: a path can legitimately name a directory
  ## that is not there yet, since `zmarkdown notes/today/plan.md` starts a new
  ## document under that name and saving it has to make room for it. On any
  ## error returns a failure outcome.
  try:
    let dir = path.parentDir()
    if dir.len > 0 and not dirExists(dir):
      createDir(dir)
    writeFile(path, content)
    ioOk(true)
  except IOError as e:
    ioErr[bool]("Could not save file: " & e.msg)
  except OSError as e:
    ioErr[bool]("Could not save file: " & e.msg)
  except CatchableError as e:
    ioErr[bool]("Could not save file: " & e.msg)

proc fileStamp*(path: string): FileStamp =
  ## Stamp a file as it is right now. A path that is not there, cannot be
  ## stat'ed, or is not an ordinary file stamps as "does not exist" - itself a
  ## state worth comparing against, since a file appearing where there was none
  ## is as much a surprise as one changing.
  if path.len == 0:
    return FileStamp()
  try:
    let info = getFileInfo(path)
    if info.kind notin {pcFile, pcLinkToFile}:
      return FileStamp()
    FileStamp(exists: true, size: info.size, mtime: info.lastWriteTime)
  except CatchableError:
    FileStamp()

func changed*(before, now: FileStamp): bool =
  ## Whether the file moved on underneath us between two stamps. Two stamps of a
  ## file that was never there compare equal, so a document that has not been
  ## written yet is never reported as changed.
  if before.exists != now.exists:
    return true
  before.exists and (before.size != now.size or before.mtime != now.mtime)
