## The three ways to look at a document, in a module of their own.
##
## Both the persisted UI state and the list of recently opened files have to
## name a view mode: the state file remembers the one last chosen, and the recent
## list remembers the one each file was last read in. A view mode is not a fact
## about recency, so parking the enum in `recent` to save a file would put it
## somewhere nobody would look for it. It lives here instead, and both reach it
## from one place.

import std/options

type
  ViewMode* = enum
    ## The three ways to look at a document.
    vmText = "text"       ## raw editor only
    vmSplit = "split"     ## editor left, preview right
    vmPreview = "preview" ## rendered preview only

func openingView*(remembered: Option[ViewMode]; blank, remembering: bool;
                  lastChosen: ViewMode): ViewMode =
  ## Which view a document opens in.
  ##
  ## A document we remember comes back the way it was left, whatever is in it -
  ## that is the whole point of remembering. Failing that, an empty document
  ## opens in Text: there is nothing to preview, and a file with nothing in it
  ## is nearly always one just created to be written in. A document with
  ## something in it opens in Preview, because opening someone's file is far
  ## more often reading it than editing it.
  ##
  ## `remembering` off means nothing is known about any file, so anything that
  ## is not empty falls back to the view last chosen by hand - which is what
  ## every file got before views were remembered at all.
  if remembered.isSome: remembered.get
  elif blank: vmText
  elif not remembering: lastChosen
  else: vmPreview

func parseViewMode*(s: string): Option[ViewMode] =
  ## A view mode read back from its persisted name, or `none` for anything that
  ## is not one: a hand-edited state file, a value from some later version, a
  ## field that was never written. Callers decide what "we do not know" means
  ## for them rather than being handed a default that looks like a choice.
  case s
  of "text": some(vmText)
  of "split": some(vmSplit)
  of "preview": some(vmPreview)
  else: none(ViewMode)
