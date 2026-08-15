import std/unittest
import "../src/core/dialogs"

# The prompts themselves need a person in front of them, but the mapping from a
# message box's answer onto what the app then does is pure, and getting it wrong
# would mean a "Cancel" that overwrites. Pin it.

suite "unsaved-changes answers":
  test "yes saves, no discards, anything else cancels":
    check savePromptOf(1) == spSave
    check savePromptOf(2) == spDontSave
    check savePromptOf(0) == spCancel

  test "an unexpected answer is treated as cancel":
    for code in [-1, 3, 99]:
      check savePromptOf(code) == spCancel

suite "changed-on-disk answers":
  test "yes overwrites, no saves elsewhere, anything else cancels":
    check conflictChoiceOf(1) == ccOverwrite
    check conflictChoiceOf(2) == ccSaveAs
    check conflictChoiceOf(0) == ccCancel

  test "an unexpected answer never overwrites":
    for code in [-1, 3, 99]:
      check conflictChoiceOf(code) == ccCancel

suite "refresh-over-unsaved-changes answers":
  test "yes keeps the changes, no takes what is on disk, anything else cancels":
    check refreshChoiceOf(1) == rcKeep
    check refreshChoiceOf(2) == rcDiscard
    check refreshChoiceOf(0) == rcCancel

  test "an unexpected answer never throws the changes away":
    for code in [-1, 3, 99]:
      check refreshChoiceOf(code) == rcCancel
