## Thin wrappers over tinyfiledialogs for the native dialogs the app needs:
## open, save-as, an unsaved-changes prompt, and an error box.
##
## On Linux tinyfiledialogs shells out to a native helper (kdialog on KDE, zenity
## elsewhere). If none is present the underlying C library degrades on its own,
## but we also guard every call so a dialog failure logs and returns a safe
## default (treated as "cancel") rather than crashing.

import pkg/tinyfiledialogs as tfd

type
  SavePrompt* = enum
    ## Result of the unsaved-changes prompt.
    spSave      ## write the changes
    spDontSave  ## discard the changes
    spCancel    ## abort the action that triggered the prompt

var logSink: proc (msg: string) {.gcsafe.} = nil

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
  try:
    # yesnocancel returns 1=yes(save), 2=no(don't save), 0=cancel.
    let r = tfd.tinyfd_messageBox(
      sanitizeForDialog(title).cstring, sanitizeForDialog(message).cstring,
      "yesnocancel".cstring, "warning".cstring, 1)
    case r
    of 1: spSave
    of 2: spDontSave
    else: spCancel
  except CatchableError as e:
    logIt("unsaved-changes prompt failed: " & e.msg)
    spCancel

proc errorDialog*(title, message: string) =
  ## Show a native error box. Never raises; a failure to show it is logged.
  try:
    discard tfd.tinyfd_messageBox(
      sanitizeForDialog(title).cstring, sanitizeForDialog(message).cstring,
      "ok".cstring, "error".cstring, 1)
  except CatchableError as e:
    logIt("error dialog failed: " & e.msg & " (message was: " & message & ")")
