## `/settings` — the compilation that makes the preset chooser a control.
##
## ## WHAT THIS BUNDLE DOES, AND HOW LITTLE OF IT THERE IS
##
## Three things:
##
##   1. Unhides the preset chooser, which `renderPresetChooser` serves `hidden`
##      so that it is never a dead radio on a page with no script.
##   2. Reveals the panel for (stored preset, this platform) and hides the
##      rest. Every panel is already in the document — see `renderPresetPanel`.
##   3. On a change, stores the choice through the same `PreferenceStore` the
##      debug route reads, and re-reveals.
##
## It renders no HTML. That is the design and not a limitation: the rows were
## produced by `components/shortcut_list.nim` at export time, by exactly the
## code that produces the debug dialog's rows, from exactly the table
## `keymap.actionFor` dispatches from. A browser-side renderer here would be a
## second implementation of "a shortcut row" living in the bundle whose whole
## purpose was to consume the first.
##
## ## WHY THE CHOICE MADE HERE CHANGES WHAT A KEY DOES OVER THERE
##
## There is no message, no event and no shared object between this page and the
## debug route. There is one `localStorage` key — `bt.ui.keymap`, per
## `Configuration.md` §4 — and `hydrate.bindShortcuts` reads it through the
## same `localPreferenceStore()` used below when a session starts.
##
## So the coupling is a stored value read at the other end, which is what makes
## the setting survive a reload, a new tab and a different transaction without
## any of them being special-cased. It is also why the demonstration that this
## works is to choose a preset here, open a trace, and PRESS THE KEY.
##
## ## AND WHY THIS IS NOT THE DEBUG BUNDLE
##
## `AGENTS.md` §1a: everything but `hydrate.nim` compiles with no debugger on
## the Nim path. This file keeps that property — it imports the keymap tables
## and the preference store, neither of which knows what a debugger is, and it
## must not grow an import that changes that. The 1.1 MB Embed SDK has no
## business in the page where a reader picks a keymap.

import std/dom

import ../src/debugger/keymap
import ../hydrate/live_preferences

proc onMac(): bool {.importjs: """
(function(){
  try {
    var d = navigator.userAgentData;
    if (d && d.platform) return /mac/i.test(d.platform);
  } catch (_) {}
  return /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent || "");
})()
""".}
  ## Which hazard column this reader gets.
  ##
  ## Byte-identical to `hydrate.onMac`, and duplicated rather than shared
  ## because the alternative is importing `hydrate.nim` — the one module that
  ## links the Embed SDK — into the bundle whose entire justification is that
  ## it does not. `userAgentData.platform` first because `navigator.platform`
  ## is deprecated and frozen in some engines; the regex over `userAgent` is
  ## the fallback that still answers where it is not.
  ##
  ## Getting this WRONG is survivable in exactly one direction and the served
  ## default is on that side: `DefaultKeymapId` is hazard-free on every
  ## platform, so a misread platform mislabels hazards only for a reader who
  ## has deliberately chosen a function-key preset.

proc panels(): seq[Element] =
  ## Every preset panel in the document.
  let all = document.querySelectorAll("[data-kb-panel]")
  for i in 0 ..< all.len:
    result.add all[i]

proc reveal(id: KeymapId; mac: bool) =
  ## Show the one panel for this preset on this platform; hide the others.
  ##
  ## HIDING IS UNCONDITIONAL AND HAPPENS TO EVERY PANEL, including the one
  ## about to be shown. Toggling only the two that change would leave the
  ## served-visible default showing underneath a newly chosen preset the first
  ## time a choice is made — two lists at once, which reads as the page
  ## disagreeing with itself about what is bound.
  let want = $id
  let wantMac = if mac: "1" else: "0"
  for p in panels():
    if $p.getAttribute("data-kb-panel") == want and
       $p.getAttribute("data-kb-mac") == wantMac:
      p.removeAttribute("hidden")
    else:
      p.setAttribute("hidden", "hidden")

proc markChosen(id: KeymapId) =
  ## Put the radio and its label in the state the store is in.
  ##
  ## `checked` is set as a PROPERTY and the class on the label as an attribute,
  ## because the served markup carries `checked="checked"` on the default and
  ## an attribute write alone does not move a rendered radio group once the
  ## document is live.
  let radios = document.querySelectorAll("input[data-kb=\"preset\"]")
  for i in 0 ..< radios.len:
    let r = radios[i]
    let on = $r.getAttribute("value") == $id
    r.checked = on
    let lbl = r.parentElement
    if lbl != nil:
      lbl.setAttribute("class", cstring(if on: "kbpreset on" else: "kbpreset"))

proc apply(id: KeymapId; mac: bool) =
  markChosen(id)
  reveal(id, mac)

proc boot() =
  let chooser = document.querySelector("[data-kb-chooser]")
  # NO CHOOSER MEANS THIS IS NOT THE SETTINGS PAGE. The bundle is deferred by
  # one route today, but a `<script>` is a URL and a build could name it on
  # another; returning is cheaper than assuming.
  if chooser == nil: return

  let store = localPreferenceStore()
  let mac = onMac()

  # THE CHOOSER BECOMES LIVE ONLY HERE, which is the promise the served
  # `hidden` makes. Between the document parsing and this line there is no
  # moment at which a reader can select a radio that would store nothing.
  chooser.removeAttribute("hidden")

  apply(store.load().keymap, mac)

  # `change` and not `click`, so a preset selected with the arrow keys — which
  # is how a radio group is operated from the keyboard, on a page about the
  # keyboard — takes effect the same way a pointer selection does.
  chooser.addEventListener("change", proc(ev: Event) =
    let t = ev.target
    if t == nil: return
    let el = Element(t)
    if $el.getAttribute("data-kb") != "preset": return
    let id = parseKeymapId($el.getAttribute("value"))
    var p = store.load()
    p.keymap = id
    store.save(p)
    apply(id, mac))

proc stillParsing(): bool {.importjs: "(document.readyState === \"loading\")".}
  ## `std/dom`'s `Document` has no `readyState` field in this Nim, so it is
  ## asked for directly rather than worked around.

when isMainModule:
  # `DOMContentLoaded` is still guarded for even though the tag is `defer`:
  # `defer` guarantees execution after parsing, but a build that inlined this
  # or dropped the attribute would otherwise run against an empty document and
  # silently do nothing — the failure mode this whole page exists to stop.
  if stillParsing():
    document.addEventListener("DOMContentLoaded", proc(ev: Event) = boot())
  else:
    boot()
