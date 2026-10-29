## Thin wrappers over tinyfiledialogs for the native dialogs the app needs:
## open, save-as, an unsaved-changes prompt, a changed-on-disk prompt, a refresh
## prompt, and information and error boxes.
##
## On Linux tinyfiledialogs shells out to a native helper (kdialog on KDE, zenity
## elsewhere). If none is present the underlying C library degrades on its own,
## but we also guard every call so a dialog failure logs and returns a safe
## default (treated as "cancel") rather than crashing.

import ../vendor/tinyfiledialogs/tinyfiledialogs as tfd

type
  SavePrompt* = enum
    ## Result of the unsaved-changes prompt.
    spSave      ## write the changes
    spDontSave  ## discard the changes
    spCancel    ## abort the action that triggered the prompt

  ConflictChoice* = enum
    ## Result of the prompt shown when the file changed on disk under us.
    ccOverwrite ## write this document over what is there now
    ccSaveAs    ## put this document somewhere else and leave that file alone
    ccCancel    ## do nothing

  RefreshChoice* = enum
    ## Result of the prompt shown when a refresh would throw away unsaved work.
    rcKeep      ## save what is in the editor first, and carry on with it
    rcDiscard   ## drop the unsaved changes and take what is on disk
    rcCancel    ## do not refresh at all

func savePromptOf*(code: int): SavePrompt =
  ## Map a yes/no/cancel box's answer onto the unsaved-changes choices.
  case code
  of 1: spSave
  of 2: spDontSave
  else: spCancel

func conflictChoiceOf*(code: int): ConflictChoice =
  ## Map a yes/no/cancel box's answer onto the changed-on-disk choices.
  case code
  of 1: ccOverwrite
  of 2: ccSaveAs
  else: ccCancel

func refreshChoiceOf*(code: int): RefreshChoice =
  ## Map a yes/no/cancel box's answer onto the refresh choices.
  case code
  of 1: rcKeep
  of 2: rcDiscard
  else: rcCancel

var logSink: proc (msg: string) {.gcsafe.} = nil
var answerHook: proc (kind: string): int {.gcsafe.} = nil

proc setDialogAnswerHook*(hook: proc (kind: string): int {.gcsafe.}) =
  ## Answer prompts from code rather than from a person. Only the headless
  ## self-test sets this: there is nobody there to click the buttons, and the
  ## flows behind these prompts are worth testing for real. `kind` is one of
  ## "unsaved", "confirm", "conflict", or "refresh"; a negative answer (or no
  ## hook) means "ask a human", which is what every normal run does.
  answerHook = hook

proc scriptedAnswer(kind: string): int =
  if answerHook == nil:
    return -1
  try:
    answerHook(kind)
  except CatchableError:
    -1

proc setDialogLogger*(sink: proc (msg: string) {.gcsafe.}) =
  ## Install a logger so dialog fallbacks are reported. Optional.
  logSink = sink

proc logIt(msg: string) =
  if logSink != nil:
    try:
      logSink(msg)
    except CatchableError:
      discard

func sanitizeForDialog(s: string): string =
  ## The Unix backends shell out, so quotes in a title or message can break the
  ## command. Strip the characters the library warns about. This only touches
  ## our own short, fixed strings and error messages, never document content.
  result = newStringOfCap(s.len)
  for c in s:
    if c notin {'"', '\'', '`'}:
      result.add c

const
  mdFilterDesc = "Markdown and text files"

proc openFileDialog*(title = "Open"): string =
  ## Show a native open-file dialog. Returns the chosen path, or "" if the user
  ## cancelled or the dialog could not be shown.
  var patterns = allocCStringArray(["*.md", "*.markdown", "*.txt", "*.*"])
  try:
    let res = tfd.tinyfd_openFileDialog(
      sanitizeForDialog(title).cstring, "".cstring,
      4, patterns, mdFilterDesc.cstring, 0)
    result = if res.isNil: "" else: $res
  except CatchableError as e:
    logIt("open dialog failed: " & e.msg)
    result = ""
  finally:
    deallocCStringArray(patterns)

proc saveFileDialog*(title = "Save As", suggestedName = "untitled.md"): string =
  ## Show a native save-file dialog. Returns the chosen path, or "" on cancel or
  ## failure.
  var patterns = allocCStringArray(["*.md", "*.markdown", "*.txt"])
  try:
    let res = tfd.tinyfd_saveFileDialog(
      sanitizeForDialog(title).cstring, suggestedName.cstring,
      3, patterns, mdFilterDesc.cstring)
    result = if res.isNil: "" else: $res
  except CatchableError as e:
    logIt("save dialog failed: " & e.msg)
    result = ""
  finally:
    deallocCStringArray(patterns)

proc unsavedChangesPrompt*(title = "Unsaved changes",
    message = "This document has unsaved changes. Save them?"): SavePrompt =
  ## Show a Save / Don't Save / Cancel prompt. On failure, default to Cancel so
  ## no data is lost.
  let scripted = scriptedAnswer("unsaved")
  if scripted >= 0:
    return savePromptOf(scripted)
  try:
    # yesnocancel returns 1=yes(save), 2=no(don't save), 0=cancel.
    savePromptOf(tfd.tinyfd_messageBox(
      sanitizeForDialog(title).cstring, sanitizeForDialog(message).cstring,
      "yesnocancel".cstring, "warning".cstring, 1).int)
  except CatchableError as e:
    logIt("unsaved-changes prompt failed: " & e.msg)
    spCancel

proc confirmPrompt*(title, message: string): bool =
  ## A plain yes/no question, defaulting to No both as the highlighted button
  ## and as the answer when the dialog cannot be shown at all: the caller is
  ## always about to throw something away.
  let scripted = scriptedAnswer("confirm")
  if scripted >= 0:
    return scripted == 1
  try:
    tfd.tinyfd_messageBox(
      sanitizeForDialog(title).cstring, sanitizeForDialog(message).cstring,
      "yesno".cstring, "warning".cstring, 0) == 1
  except CatchableError as e:
    logIt("confirm prompt failed: " & e.msg)
    false

proc diskConflictPrompt*(name: string, gone: bool): ConflictChoice =
  ## Ask what to do about a file that changed on disk since it was opened.
  ## Defaults to Cancel, so a dialog that cannot be shown never overwrites
  ## somebody else's work.
  let scripted = scriptedAnswer("conflict")
  if scripted >= 0:
    return conflictChoiceOf(scripted)
  let message =
    if gone:
      name & " is no longer on disk: something else deleted or moved it after " &
        "you opened it.\n\nWrite this document back out to that name?\n\n" &
        "Yes: write it out again\nNo: save it somewhere else\nCancel: do nothing"
    else:
      name & " has been changed on disk since you opened it. Saving now would " &
        "overwrite those changes.\n\n" &
        "Yes: overwrite them\nNo: save this document somewhere else\n" &
        "Cancel: do nothing"
  try:
    conflictChoiceOf(tfd.tinyfd_messageBox(
      "File changed on disk".cstring, sanitizeForDialog(message).cstring,
      "yesnocancel".cstring, "warning".cstring, 0).int)
  except CatchableError as e:
    logIt("changed-on-disk prompt failed: " & e.msg)
    ccCancel

proc refreshPrompt*(name: string): RefreshChoice =
  ## Ask what a refresh should do about unsaved changes: keep them (by saving
  ## them first), throw them away for whatever is on disk, or leave everything
  ## alone. Defaults to Cancel, so a dialog that cannot be shown never costs
  ## anyone their work.
  let scripted = scriptedAnswer("refresh")
  if scripted >= 0:
    return refreshChoiceOf(scripted)
  let message = name & " has unsaved changes, and refreshing replaces them with " &
    "what is on disk.\n\n" &
    "Yes: keep my changes - save them first, then refresh\n" &
    "No: discard my changes and load what is on disk\n" &
    "Cancel: do not refresh"
  try:
    refreshChoiceOf(tfd.tinyfd_messageBox(
      "Refresh".cstring, sanitizeForDialog(message).cstring,
      "yesnocancel".cstring, "warning".cstring, 0).int)
  except CatchableError as e:
    logIt("refresh prompt failed: " & e.msg)
    rcCancel

proc infoDialog*(title, message: string) =
  ## Show a native information box for something that is worth saying but is not
  ## an error. Never raises.
  try:
    discard tfd.tinyfd_messageBox(
      sanitizeForDialog(title).cstring, sanitizeForDialog(message).cstring,
      "ok".cstring, "info".cstring, 1)
  except CatchableError as e:
    logIt("info dialog failed: " & e.msg & " (message was: " & message & ")")

proc errorDialog*(title, message: string) =
  ## Show a native error box. Never raises; a failure to show it is logged.
  try:
    discard tfd.tinyfd_messageBox(
      sanitizeForDialog(title).cstring, sanitizeForDialog(message).cstring,
      "ok".cstring, "error".cstring, 1)
  except CatchableError as e:
    logIt("error dialog failed: " & e.msg & " (message was: " & message & ")")
