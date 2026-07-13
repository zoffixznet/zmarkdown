## File read/write with error handling. Every predictable IO failure is turned
## into a Result the caller can act on (show a dialog, keep the document), never
## an exception that takes down the app.

type
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
  ## Write text to a file, replacing any existing contents. On any error returns
  ## a failure outcome.
  try:
    writeFile(path, content)
    ioOk(true)
  except IOError as e:
    ioErr[bool]("Could not save file: " & e.msg)
  except OSError as e:
    ioErr[bool]("Could not save file: " & e.msg)
  except CatchableError as e:
    ioErr[bool]("Could not save file: " & e.msg)
