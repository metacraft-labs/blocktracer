## Settings (`/settings`) — the keyboard shortcuts, chosen and listed.
##
## ## THIS PAGE IS NOT THE ONE THAT WAS DELETED
##
## A page at this address was removed wholesale in `2e0499c`, and nothing of it
## returns here. That page was a PRIVACY DISCLOSURE WEARING A SETTINGS TITLE:
## four groups of prose, no control anywhere, each group naming a preference it
## would one day manage and explaining why it could not manage it yet. Its two
## facts worth keeping went to `/about`, where a reader who wants them looks.
##
## The reason it had no controls was stated in its own header — "reading or
## writing any of them needs script, and this client ships none" — and that
## sentence was FALSE when it was written. `client/hydrate/hydrate.js` is 1.1 MB
## of this product's script, and `client/searchboot/search.js` is 40 KB more.
## What was true is narrower: no bundle was loaded on THIS route. That is a
## build wiring fact, not a property of the product, and it is fixed by wiring
## a bundle rather than by explaining the absence well.
##
## ## WHAT THIS PAGE IS
##
## One setting, because one setting is what exists: which keyboard preset the
## debugger binds. And the full list of what is bound, which is the other half
## of the same question — a preset chooser without a list makes a reader select
## a name and go and find out what it did.
##
## The list covers all three registries that can claim a key on this product's
## debug route, not just the presets. `components/shortcut_list.nim` says why
## at length; the short form is that a page headed "the full list" which omits
## the scrubber's arrows and `hydrate.nim`'s own `Enter`/Space/`Escape` is the
## most useful-looking kind of wrong, because a reader consults it precisely to
## learn what a key does.
##
## ## WHERE THE SETTING TAKES EFFECT, AND WHY THAT SENTENCE IS ON THE PAGE
##
## Not here. The keys act on a transaction's debug route, which is where a
## trace is being stepped through. One line says so, because a chooser whose
## effect is invisible on the page containing it is a control a reader cannot
## confirm — they press `n` on the settings page, nothing happens, and what
## they learn is that the setting did not work.
##
## That line is the only prose on this page, and it is navigational rather than
## explanatory: it tells a reader where to go to see the thing they just
## changed. Nothing here announces what is stored, where, or what is not sent
## anywhere — `components/debugger.nim` records why that footnote was removed
## from the dialog, and the same reasoning governs the page. The persistence is
## demonstrated by the choice surviving a reload.

import isonim/ssr/escape
import isonim/dsl/ui

import ../components/shortcut_list
import ../debugger/keymap

proc settingsPage*(): string =
  ## The chooser, then every preset's rows, then the two registries that are
  ## the same under every preset.
  ##
  ## `DefaultKeymapId` is the panel served visible. It is the right one for a
  ## reader with no script for a reason stronger than "it is the default": with
  ## no script the debug route binds NO stepping key at all — `controlLabel`'s
  ## `kmNone` note — so no stored choice can exist to contradict it, because
  ## storing one requires the bundle that also does the binding.
  ##
  ## BOTH PLATFORM VARIANTS of every preset are emitted. See
  ## `renderPresetPanel` for why the pair is the honest unit and why the served
  ## default costs nothing.
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          span: text "settings"
        h1(class = "h1"): text "Keyboard shortcuts"
        p(class = "lead"):
          text "These keys step a recorded trace. They act on a "
          text "transaction's debugger, not on this page."

        raw renderPresetChooser(DefaultKeymapId, served = true)

        for id in KeymapId:
          for mac in [false, true]:
            raw renderPresetPanel(
              id, mac, visible = (id == DefaultKeymapId and not mac))

        # THE GROUP IS NAMED FROM THE TABLE, not here. `ScrubName` is what the
        # scrubber's own `aria-label` calls it, so the heading and the control
        # a reader tabs to give the same name to the same thing.
        h2(class = "sec-title next"): text ScrubName
        raw renderScrubRows()

        h2(class = "sec-title next"): text "Always active"
        raw renderHardRows()
