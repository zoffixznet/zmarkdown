## The command line, read into a plain record the app can act on.
##
## `zmarkdown [options] [file ...]`: every path given is a document to open, one
## window each. Switches and paths may be mixed in any order; `--` ends the
## switches so a path that starts with a dash can still be opened. Nothing here
## touches the process: the caller decides what to print, what to spawn, and
## whether the terminal hears anything at all.

import std/[strutils, uri]

type
  Launch* = object
    files*: seq[string]
      ## Every document path given, in order, exactly as written. The first is
      ## for this window; each of the rest gets a window of its own.
    selfTest*: bool     ## run the headless end-to-end self-test and exit
    probeGl*: bool      ## internal: act as the isolated GL probe helper
    forceCpu*: bool     ## --no-gpu
    forceGpu*: bool     ## --gpu
    verbose*: bool      ## log more detail (implies debugOutput)
    debugOutput*: bool  ## leave the terminal attached: log lines, library warnings
    showVersion*: bool
    showHelp*: bool
    unknown*: seq[string]
      ## Switches nobody recognised. Reported (when anyone is listening) and
      ## otherwise ignored, rather than mistaken for file names.

proc parseLaunch*(args: openArray[string]): Launch =
  ## Read the arguments as given (without the program name).
  var onlyFiles = false
  for arg in args:
    if arg.len == 0:
      continue  # an unset shell variable, as in `zmarkdown "$FILE"`: not a path
    if onlyFiles:
      result.files.add arg
      continue
    case arg
    of "--": onlyFiles = true
    of "--self-test": result.selfTest = true
    of "--probe-gl": result.probeGl = true
    of "--no-gpu": result.forceCpu = true
    of "--gpu": result.forceGpu = true
    of "--verbose", "-v": result.verbose = true
    of "--debug-output": result.debugOutput = true
    of "--version": result.showVersion = true
    of "--help", "-h": result.showHelp = true
    else:
      if arg.len > 1 and arg[0] == '-':
        result.unknown.add arg
      else:
        result.files.add arg

func keepsTerminalOutput*(l: Launch; debugBuild: bool): bool =
  ## Whether this run may write to the terminal it was started from. A normal
  ## launch must not: `zmarkdown notes.md &` is how people start it, and a line
  ## on every save is noise in whatever they are doing in that terminal. The
  ## runs that exist to print something (help, version, the self-test), and the
  ## runs where somebody asked to see the log, keep it; so do debug builds,
  ## which exist to be watched.
  debugBuild or l.debugOutput or l.verbose or l.selfTest or l.showHelp or
    l.showVersion

func inheritedFlags*(l: Launch): seq[string] =
  ## The switches another window started from this one should be given, so it
  ## renders the same way and is as talkative. Documents are not among them: a
  ## new window starts empty, and a sibling gets exactly one file of its own.
  if l.forceCpu: result.add "--no-gpu"
  if l.forceGpu: result.add "--gpu"
  if l.verbose: result.add "--verbose"
  if l.debugOutput: result.add "--debug-output"

func siblingArgs*(l: Launch; file: string): seq[string] =
  ## The whole command line for a window opening one of the other files given.
  result = l.inheritedFlags()
  if file.len > 0 and file[0] == '-':
    result.add "--"
  result.add file

proc normalizeFilePath*(arg: string): string =
  ## A path as a desktop hands it over: a file:// URL (which is what some file
  ## managers and drag-and-drop pass) becomes the plain path it names, with its
  ## percent-escapes undone. Anything else is returned untouched.
  if not arg.toLowerAscii().startsWith("file://"):
    return arg
  result = arg[7 .. ^1]
  try:
    result = decodeUrl(result, decodePlus = false)
  except CatchableError:
    discard
