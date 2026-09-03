## The keyboard shortcuts, rendered once, for every surface that shows them.
##
## ## WHY THIS IS A MODULE AND NOT TWO RENDERERS
##
## `keymap.nim`'s premise is ONE TABLE, THREE READERS: `actionFor` dispatches,
## `chordFor` labels, and a list iterates. That held while the only list was
## the debug route's dialog. The moment `/settings` also lists the shortcuts
## there are two lists, and two lists rendered by two procs is the same defect
## one level up — the dialog and the settings page free to show the same
## binding differently, or one of them to grow a hazard column the other lacks.
##
## So the rows are produced HERE, and `components/debugger.renderShortcutsDialog`
## and `pages/settings.settingsPage` both call in. Neither owns a row.
##
## ## WHAT "THE FULL LIST" HAD TO GROW TO MEAN
##
## The dialog listed `km.bindings` and called that the shortcuts. It is not.
## Three registries can claim a key on this surface and the dialog enumerated
## one and a half of them:
##
##   1. `keymap.nim`'s preset bindings — the stepping chords. Listed.
##   2. `keymap.nim`'s `ScrubKeys` — the scrubber's arrows, `PageUp`/`PageDown`,
##      `Home`/`End`. A real table with a real dispatcher, and the dialog never
##      drew a row for it; it reached a reader only through the track's own
##      `aria-keyshortcuts`.
##   3. `hydrate.nim`'s direct claims — `Enter`/Space on the breakpoint gutter,
##      `Escape` on the dialog. Not a table at all until `hard_keys.nim`, which
##      derives them from the source that claims them.
##
## All three are drawn below, because a page headed "the full list of active
## shortcuts" that silently omits a third of the keys the page answers to is
## the most useful-looking kind of wrong: a reader consults it precisely to
## learn what a key does.
##
## ## THE SHADOW COLUMN, which is what makes the list TRUE rather than PLAUSIBLE
##
## Registry 3 runs BEFORE registry 1. `bindShortcuts` tests `Escape` and
## returns; the gutter's `activationKey` fires on its own element. So a preset
## that bound one of those keys would produce a row that is true about the
## table and false about the browser — `actionFor` would agree the chord is
## bound, the dialog would draw it, and the key would do the other thing.
##
## `shadowOf` asks `hard_keys.hardClaim` per row, so the list reports the
## override instead of being contradicted by it. Today no preset collides and
## every row is clean; the value is that the day one does, the row says so
## rather than the visitor discovering it by pressing the key.



import isonim/ssr/escape
import isonim/dsl/ui

import ../debugger/keymap
import ../debugger/hard_keys
import ../debugger/session_view

func shadowOf*(c: Chord): (bool, string) =
  ## Does something outside the keymap claim this chord's key first?
  ##
  ## ONLY FOR AN UNMODIFIED CHORD, and the restriction is the accurate one
  ## rather than a simplification. `hard_keys` derives comparisons against
  ## `KeyboardEvent.key` alone — `activationKey` tests `e.key === "Enter"` with
  ## no regard for modifiers, and so does the `Escape` branch — so `Ctrl+Enter`
  ## IS caught by them too and genuinely is shadowed.
  ##
  ## That is why the modifier bits are not consulted here: adding
  ## `if c.ctrl or c.alt …: return (false, "")` would be a guess that the
  ## claiming code is modifier-aware, and it is not. Reporting the shadow on a
  ## modified chord is correct, and it is what the claiming source says.
  hardClaim(c.key)

proc presetRadios(active: KeymapId): string =
  ## The four radios, so `renderPresetChooser`'s two branches differ only in
  ## the wrapper's attributes and cannot drift in their contents.
  ui:
    tdiv(class = "kbpresets"):
      for id in KeymapId:
        let on = id == active
        label(class = "kbpreset" & (if on: " on" else: "")):
          # AN ATTRIBUTE IS EMITTED OR IT IS NOT — see `renderPresetChooser`.
          if on:
            input(class = "kbradio", `type` = "radio", name = "kbpreset",
                  value = $id, `data-kb` = "preset", checked = "checked")
          else:
            input(class = "kbradio", `type` = "radio", name = "kbpreset",
                  value = $id, `data-kb` = "preset")
          span(class = "kbpresetname"): text presetName(id)
          span(class = "kbpresetwhy"): text presetWhy(id)

proc renderPresetChooser*(active: KeymapId; served: bool): string =
  ## The four presets as a radio group.
  ##
  ## ## IT IS SERVED `hidden`, AND THAT IS THE PRODUCT'S RULE, NOT A DEFAULT
  ##
  ## A radio a visitor can select that stores nothing is a control that cannot
  ## succeed, and `Page-Descriptions.md` §13 settles what this product does
  ## about those: it does not ship them. `renderShortcutsButton` says the same
  ## thing about the gear — "a gear on the served, script-less page would open
  ## nothing" — and solves it by having hydration insert the control.
  ##
  ## The settings page cannot use that solution as-is, because the ROWS below
  ## must be present without script (they are the honest answer to "what is
  ## bound", and they are what a crawler and a reader with no JS get). So the
  ## chooser is served, but `hidden`, and the bundle unhides it in the same
  ## compilation that makes it store anything. A visitor with no script sees
  ## the list and no chooser — which is exactly true: with no script there is
  ## nothing to choose, because the debug route binds no key without its
  ## bundle either.
  ##
  ## `data-kb-chooser` is the handle for that, and is what a check counts.
  ##
  ## `served` DISTINGUISHES THE TWO CALLERS, and only one of them needs the
  ## hiding. The debug route's dialog is itself inserted by the bundle — it
  ## does not exist on a script-less page at all — so its chooser is live the
  ## moment it is in the DOM and must not be `hidden`. The settings page is
  ## served as static bytes, so its chooser is `hidden` until the bundle that
  ## makes it store something unhides it. Passing `served = true` from the
  ## settings page and `false` from the dialog is therefore a statement about
  ## WHO IS RENDERING, not a display preference.
  ## ## AN ATTRIBUTE IS EMITTED OR IT IS NOT — THERE IS NO EMPTY ONE
  ##
  ## Every conditional attribute below is written as two element calls under an
  ## `if`, and never as one call with `attr = (if on: "x" else: "")`. That
  ## shorter form is WRONG in a way that produces no error and no warning, and
  ## it shipped:
  ##
  ##   * isonim's `ui:` always emits the attribute it is given, so the false
  ##     branch renders `checked=""` rather than nothing.
  ##   * `checked` is an HTML BOOLEAN attribute, and a boolean attribute is
  ##     true WHEN PRESENT, whatever its value. `checked=""` is checked.
  ##
  ## So the dialog's picker marked ALL FOUR radios checked, a radio group keeps
  ## the last such, and the surface a visitor opens to see which preset is in
  ## force always showed `None` — under every preset, including while the
  ## chords of another one were demonstrably working. Journey 22 found it by
  ## reading the radio a visitor would read; every existing check looked at the
  ## ROWS, which were correct the whole time.
  ##
  ## The nested `if` is safe here for the reason `components/layout.nim`
  ## records: a nested `if` goes through `ssrChildrenExpr`, which renders its
  ## branches. Only a TOP-LEVEL `if` in a `ui:` body evaporates.
  ##
  ## `served` GOES THROUGH THE SAME `if` for the same reason, and this one bit
  ## twice over: written as `hidden = (if served: "hidden" else: "")` it emitted
  ## `hidden=""` on the DIALOG's chooser — hiding the preset picker inside the
  ## surface whose whole purpose is to offer it.
  ##
  ## AND THE BRANCH IS A GUARD, NOT AN `if` INSIDE `ui:` — the top-level `if`
  ## evaporates, which is the trap `renderBindingRows` records. It was hit
  ## again right here while fixing the `hidden=""` bug above, so both failure
  ## modes of a conditional attribute have now been made in this one proc.
  let radios = presetRadios(active)
  if served:
    return ui:
      tdiv(class = "kbchooser", `data-kb-chooser` = "", hidden = "hidden",
           role = "radiogroup", `aria-label` = "Shortcut preset"):
        raw radios
  ui:
    tdiv(class = "kbchooser", `data-kb-chooser` = "",
         role = "radiogroup", `aria-label` = "Shortcut preset"):
      raw radios

proc renderNoBindings(): string =
  ## `kmNone`, which is a CHOICE a visitor can make.
  ##
  ## A sentence and not an empty table: an empty table reads as a surface that
  ## failed to load, which is the one thing a list of shortcuts must never look
  ## like. A reader who has just turned stepping shortcuts off wants to know
  ## the buttons still work.
  ui:
    p(class = "kbempty"):
      text "No stepping shortcuts are bound. The toolbar buttons still work."

proc renderBindingRows*(km: Keymap; mac: bool): string =
  ## Registry 1: the preset's stepping chords.
  ##
  ## Every row comes from iterating `km.bindings` — the same sequence
  ## `actionFor` matches a press against. There is no list here to fall out of
  ## date and there cannot be one, because the loop has nothing to read but
  ## the bindings themselves. `data-kb-rows` publishes the count so a check
  ## reads it off the rendered set rather than off an intention.
  ##
  ## ## THE EMPTY CASE IS A GUARD AND A SEPARATE PROC, NOT AN `if` INSIDE `ui:`
  ##
  ## It was written as a top-level `if/else` in the `ui:` body first, and that
  ## renders as NOTHING — silently. `components/layout.nim` documents the trap
  ## at length above `hydrationScriptTag`: a top-level `if` never reaches
  ## `ssrNodeExpr`, so the whole block evaporates and the page is simply
  ## missing an element nobody asked about. It cost a red suite here, which is
  ## the good outcome; the bad one is a served page quietly losing its rows.
  ##
  ## The shape that cannot fail is the one that file settled on: the branch
  ## returns BEFORE the `ui:`, so the `ui:` body is a single element call.
  if km.bindings.len == 0:
    return renderNoBindings()
  ui:
    tdiv(class = "kbrows", `data-kb-rows` = $km.bindings.len):
      for b in km.bindings:
        let hz = hazardOf(b.chord, mac)
        let (shadowed, by) = shadowOf(b.chord)
        tdiv(class = "kbrow", `data-kb-action` = $b.action):
          span(class = "kbwhat"): text controlLabel(b.action)
          kbd(class = "kbchord"): text describe(b.chord)
          if hz != hzNone:
            span(class = "kbhazard" & (if hz == hzBrowserReserved:
                                         " blocked" else: " maybe"),
                 `data-kb-hazard` = (if hz == hzBrowserReserved:
                                       "reserved" else: "mac-fn")):
              text hazardText(hz)
          # THE SHADOW, reported where the collision would be experienced.
          # No preset collides today; this renders nothing, and the assertion
          # in the test suite is what holds that true rather than this `if`
          # never being exercised meaning it cannot happen.
          if shadowed:
            span(class = "kbhazard blocked", `data-kb-shadow` = "hard"):
              text "this page already uses this key to: "
              text by

proc renderScrubRows*(): string =
  ## Registry 2: the scrubber's keys.
  ##
  ## Drawn from `scrubBindings()`, the same table `scrubMoveFor` dispatches
  ## from. These are NOT a preset and carry no radio — `ArrowLeft` on a focused
  ## slider is what the platform's own slider does, and rebinding it would
  ## break the convention that makes the control legible without being read
  ## about. `keymap.nim` says so at length above `ScrubKeys`; the consequence
  ## here is that this block is identical under every preset.
  ui:
    tdiv(class = "kbrows", `data-kb-scrub-rows` = $scrubBindings().len):
      for b in scrubBindings():
        tdiv(class = "kbrow", `data-kb-scrub` = $b.move):
          # THE MOVE ALONE, not `ScrubName & ", " & $b.move`. That form put
          # "Position in the trace," in front of all six rows — the same eleven
          # words six times, wrapping the label column onto two lines each — and
          # said nothing the group heading above does not. `ScrubName` is what
          # the CONTROL is called and belongs on the group, not on every row.
          span(class = "kbwhat"): text $b.move
          span(class = "kbchordset"):
            for i, k in b.keys:
              if i > 0:
                span(class = "kbor"): text " or "
              kbd(class = "kbchord"): text keyLabel(k)

proc renderHardRows*(): string =
  ## Registry 3: the keys claimed in `hydrate.nim` itself.
  ##
  ## `hardKeys()` is derived by `staticRead` from the file that claims them, so
  ## this block cannot list a key that is no longer claimed, nor omit one that
  ## is. Grouped by description rather than one row per key, because Space and
  ## its legacy `Spacebar` spelling are ONE key to a reader and two only to an
  ## engine — three rows saying the same sentence would read as three different
  ## shortcuts.
  var seen: seq[string]
  var groups: seq[tuple[what: string; keys: seq[string]]]
  for h in hardKeys():
    let at = seen.find(h.what)
    if at < 0:
      seen.add h.what
      groups.add (what: h.what, keys: @[h.key])
    else:
      groups[at].keys.add h.key
  ui:
    tdiv(class = "kbrows", `data-kb-hard-rows` = $groups.len):
      for g in groups:
        tdiv(class = "kbrow", `data-kb-hard` = "1"):
          span(class = "kbwhat"): text g.what
          span(class = "kbchordset"):
            for i, k in g.keys:
              if i > 0:
                span(class = "kbor"): text " or "
              kbd(class = "kbchord"): text keyLabel(k)

proc renderPresetPanel*(id: KeymapId; mac: bool; visible: bool): string =
  ## One preset's stepping rows, on one platform, addressable by the bundle.
  ##
  ## ## EVERY PANEL IS SERVED AND THE BUNDLE UNHIDES ONE
  ##
  ## Rather than the bundle building rows for the stored preset in the browser.
  ## Two reasons, and the second decides it:
  ##
  ##   * The rows are then rendered by exactly the code that renders the
  ##     dialog's, in the same compilation, from the same table. A browser-side
  ##     renderer would be a second implementation of "a row" — the defect this
  ##     module was extracted to prevent, reintroduced in the bundle that was
  ##     supposed to consume it.
  ##   * The complete truth is in the served bytes. A reader with no script,
  ##     and a crawler, get every preset's full list rather than a container
  ##     that would have been filled in.
  ##
  ## The bundle's whole job is therefore an attribute toggle.
  ##
  ## ## AND WHY THE PLATFORM IS PART OF THE PANEL'S IDENTITY
  ##
  ## `hazardOf` is a function of the chord AND the platform — `F10` is a plain
  ## function key on Linux and a media key on a default Mac — so "the rows for
  ## the VS Code preset" is not one answer, it is two. Static bytes cannot know
  ## which; there is no `navigator` at export time.
  ##
  ## So both are served, keyed by `data-kb-mac`, and the bundle reveals the
  ## pair (preset, platform) it can see. The alternative — rendering one
  ## platform's hazards and letting the other half of the readership have them
  ## wrong — is the exact failure `hazardOf` exists to prevent, moved from the
  ## keymap into the page that displays it.
  ##
  ## WITHOUT SCRIPT THIS COSTS NOTHING, which is not luck: the served-visible
  ## panel is `DefaultKeymapId`, and the default is hazard-free on EVERY
  ## platform — `keymap.nim` chose it for that property and the suite asserts
  ## it. So the two variants of the panel a script-less reader might be shown
  ## are byte-identical, and the choice between them cannot be wrong.
  ##
  ## ## AND `hidden` IS EMITTED OR IT IS NOT — NEVER `hidden=""`
  ##
  ## Written as `hidden = (if visible: "" else: "hidden")` this rendered
  ## `hidden=""` on the one panel meant to be SHOWN, and `hidden` is an HTML
  ## boolean attribute — true when present, whatever its value. So every panel
  ## was hidden and a reader with no script got a settings page with no
  ## shortcut list on it at all: the complete-in-the-served-bytes property this
  ## proc's header claims, silently absent, in the build that claimed it.
  ##
  ## Journey 22 caught it on the script-less pass. The Nim suite did not and
  ## could not: it asserted `hidden=""` was present on exactly one panel, which
  ## was TRUE and was the bug written down as an expectation.
  let rows = renderBindingRows(keymapOf(id), mac)
  let macAttr = if mac: "1" else: "0"
  if visible:
    return ui:
      tdiv(class = "kbpanel", `data-kb-panel` = $id, `data-kb-mac` = macAttr):
        raw rows
  ui:
    tdiv(class = "kbpanel", `data-kb-panel` = $id, `data-kb-mac` = macAttr,
         hidden = "hidden"):
      raw rows
