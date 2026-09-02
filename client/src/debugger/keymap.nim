## The stepping chords: one table, read by everything that needs to know one.
##
## ## Why this module exists at all, and what it is written against
##
## `session_view.controlLabel` used to carry a long note explaining that the
## tooltips name no chord because there IS no chord — "the only `keydown`
## handler on the controls is the scrubber's arrow-key seek, and no stepping
## command is bound to a key anywhere in the bundle". That was true and is no
## longer. This module is what makes it false, and the note it replaces ends
## with the constraint this file is shaped by:
##
##     When one exists it composes HERE, into the one string the toolbar
##     already reads, so it cannot be added to the tooltip without also being
##     bound.
##
## So there is ONE table. `actionFor` dispatches a key press through it,
## `chordFor` renders a tooltip through it, and the shortcuts dialog lists it
## by iterating it. A chord that is not in the table is displayed by nobody,
## and a chord that is in it is dispatched by the handler — the two cannot
## drift, because there is no second place for either to be written down.
##
## That is not a hypothetical failure. `Debugger-Integration.md` §10.5 records
## it happening in this very repository's sibling docs: `Debugger-Controls.md`
## gives Reverse Continue as `Shift+F5` *and gives `Shift+F5` to Stop as well,
## in the same table*, while `Keyboard-Shortcuts-System.md` gives
## `reverseContinue: SHIFT+F8`. Two documents, one keymap, already disagreeing.
## A third copy in a tooltip would be the one a visitor believes.
##
## ## THE F-KEY PROBLEM, which is the whole reason the desktop set is not simply
## ## adopted
##
## CodeTracer's desktop bindings are `F8` / `F10` / `F11` / `F12` with `Shift`
## for the reverse of each (`GUI/Keyboard-Shortcuts-System.md` §"Default
## bindings"). Every one of those is compromised in a page inside somebody
## else's browser, and in three different ways:
##
##   * `F12` opens the developer tools. A page cannot `preventDefault` it —
##     it is consumed by the browser before the event is dispatched to the
##     document at all.
##   * `F11` is fullscreen, with the same standing.
##   * On macOS — which is where the report that started this came from —
##     `F8`, `F10`, `F11` and `F12` are the system media and Mission Control
##     keys unless the visitor has turned on "Use F1, F2, etc. keys as standard
##     function keys", or holds `Fn`. So on the default Mac the desktop set
##     does not reach the page even in principle.
##
## This is why the presets below exist rather than one set: the honest answer
## is not a single keymap, it is a choice with the trade-off stated, and
## `hazardOf` is how the dialog states it. A preset that a platform will eat is
## not hidden — it is offered with the hazard named, because a visitor who has
## already set their Mac's function-key preference is entitled to the desktop
## bindings they know.
##
## ## WHY UNMODIFIED SINGLE LETTERS ARE AVAILABLE HERE
##
## They are unavailable in an editor because a letter is text. This surface is
## not an editor: the debugger is read-only, it has no text entry on the
## stepping route, and a bare letter therefore collides with nothing. Two
## precedents, both already in this product's own specifications:
##
##   * `Page-Descriptions.md` §13 already binds bare letters site-wide: "`/`
##     focuses search, `d` opens the debugger from a transaction page". The
##     product has already decided that an unmodified key is an acceptable
##     gesture on a reading surface.
##   * `Debugger-UX-Research.md` §3.2 records a direct competitor doing exactly
##     this in exactly this product category: "Walnut added `b` (step back),
##     `n` (step into), `o` (step over) as keyboard shortcuts", and the same
##     section's take is that single-letter shortcuts are "the most directly
##     actionable small finding in the document".
##
## `isTypingTarget` is what keeps that safe as the product grows a text field.
## It is applied at the dispatch site rather than assumed here.

import std/[strutils]
import ./session_view

type
  Chord* = object
    ## One key press, in the vocabulary the browser reports it in.
    ##
    ## `key` is `KeyboardEvent.key` VERBATIM — "F10", "n", "N", "ArrowRight" —
    ## and not a `code`, not a keyCode, and not a lowercased normalisation.
    ##
    ## That choice is load-bearing and was not free. `KeyboardEvent.key` is the
    ## character the visitor's layout actually produced, so a binding on `n`
    ## fires on the key that types an `n` whatever the layout calls it
    ## physically; `code` would name a US-QWERTY position and would put the
    ## step-over chord somewhere else entirely on a Dvorak or AZERTY keyboard.
    ##
    ## SHIFT IS NOT A SEPARATE FLAG FOR LETTERS, and this is the subtlety that
    ## makes a naive implementation wrong. The browser reports `Shift`+`n` as
    ## `key == "N"` — the shifted CHARACTER, not `"n"` with a shift bit. So the
    ## reverse of a letter chord is spelled here as the capital letter and
    ## `shift` stays false; writing `Chord(key: "n", shift: true)` would build a
    ## binding no event can ever equal. For function keys the browser does the
    ## opposite — `Shift`+`F10` is `key == "F10"` with `shiftKey` true — so
    ## `shift` exists and is used there, and only there.
    key*: string
    shift*: bool
    ctrl*: bool
    alt*: bool
    meta*: bool

  KeymapId* = enum
    ## Which preset is in force. The string values are the wire spellings: they
    ## go into `localStorage` under `bt.ui.keymap` (`Configuration.md` §4) and
    ## into the dialog's radio values, so renaming one is a migration and not a
    ## rename.
    kmLetters = "letters"
    kmVsCode = "vscode"
    kmDesktop = "desktop"
    kmNone = "none"

  Binding* = object
    action*: DebugAction
    chord*: Chord

  Keymap* = object
    id*: KeymapId
    bindings*: seq[Binding]

  Hazard* = enum
    ## What the platform will do to a chord before the page sees it.
    ##
    ## Derived from the chord, never stored beside it, so a preset cannot
    ## claim a key is safe that this function knows is not.
    hzNone
    hzBrowserReserved   ## the browser consumes it; the page never sees it
    hzMacFunctionKey    ## a media key on macOS unless the visitor changed a setting
    hzShadowsBrowser    ## the page CAN take it, but it is also a browser habit

func chord*(key: string; shift = false; ctrl = false; alt = false;
            meta = false): Chord =
  Chord(key: key, shift: shift, ctrl: ctrl, alt: alt, meta: meta)

func `==`*(a, b: Chord): bool =
  a.key == b.key and a.shift == b.shift and a.ctrl == b.ctrl and
    a.alt == b.alt and a.meta == b.meta

# ---------------------------------------------------------------------------
# THE PRESETS
# ---------------------------------------------------------------------------
#
# Three, and each is here because a survey of what in-browser debuggers
# actually bind produced it. None of them is a taste.
#
# ## THE SURVEY'S STRONGEST SINGLE FINDING, AND WHAT IT DECIDED HERE
#
# Every browser debugger that took the F-key problem seriously ships a SECOND,
# non-F-key chord for each stepping command — and three of them independently
# ship the SAME one:
#
#   Chrome DevTools (documented, developer.chrome.com/docs/devtools/shortcuts):
#     resume Cmd/Ctrl+\  step over Cmd/Ctrl+'  step into Cmd/Ctrl+;
#     step out Cmd/Ctrl+Shift+;
#   WebKit's Web Inspector (undocumented by Apple; verified in
#     Source/WebInspectorUI/UserInterface/Base/Main.js): the identical four.
#   AWS Cloud9 (documented, per-OS keybinding reference): the same four again,
#     as the macOS column beside F8/F10/F11/Shift+F11.
#
# Firefox is the instructive outlier: same F-keys on every platform, no
# alternative, and a documentation note telling Mac users to hold Fn.
#
# So the survey decides one thing unambiguously — THE DEFAULT MUST NOT BE AN
# F-KEY SET — and `DefaultKeymapId` obeys it.
#
# IT DOES NOT DECIDE THE SECOND THING, and the punctuation family is
# deliberately not copied, for two reasons that are about `KeyboardEvent.key`
# rather than about taste:
#
#   * PUNCTUATION IS LAYOUT-DEPENDENT in a way letters are not. `;` and `'` sit
#     on different physical keys on AZERTY and produce different characters
#     under Shift on nearly every non-US layout. Chrome and WebKit dispatch
#     these from a keyCode — a physical position — which this page cannot
#     reach; a `key`-based table would bind them somewhere else entirely for a
#     French or German visitor.
#   * `Alt` COMPOSES ON macOS. Option+`;` is `…`, not `;` with a bit set — so
#     the obvious way to spell the eight reverse moves this product needs, from
#     a source that defines only four forward ones, does not survive contact
#     with the platform the reverse set matters most on. (It is safe with
#     function keys, whose `key` Alt does not alter, which is why the VS Code
#     preset uses it and this one would not.)
#
# The letters preset reaches the same destination — every chord arrives, no
# F-key involved — by a route that is layout-stable and that a read-only
# surface can afford. That is the survey applied, not overruled.

const LettersBindings = [
  # THE DEFAULT, and the only preset with no platform hazard on any chord.
  #
  # The letters are gdb's, which is the most widely known single-letter
  # debugger keymap there is: `n` next (step over), `s` step (into), `f`
  # finish (step out), `c` continue. A visitor who has used a command-line
  # debugger already knows three of the four.
  #
  # THE REVERSE OF EACH IS ITS CAPITAL, which is `Shift` — inheriting the
  # desktop app's own rule rather than inventing one. `Keyboard-Shortcuts-
  # System.md` binds `SHIFT+F8`, `SHIFT+F10`, `SHIFT+F11`, `SHIFT+F12` as the
  # reverse of `F8`/`F10`/`F11`/`F12`; "Shift means backwards" is therefore
  # already this product family's convention and is carried over intact.
  #
  # AND THE SET IS SYMMETRIC, which is a deliberate divergence from every
  # hosted competitor surveyed. `Debugger-UX-Research.md` §3.2 notes of
  # Walnut's three shortcuts that "only one of them is backwards" and adds:
  # "Nobody hosted has a symmetric reverse set." This product's premise is that
  # time runs both ways — `session_view.DebugAction` puts the backward move
  # FIRST in each toolbar pair for that reason — so a keymap with four forward
  # chords and one backward one would contradict the toolbar it labels.
  #
  # ## WHY NO SURVEYED PRODUCT SHIPS THIS, AND WHY THAT IS NOT AN ARGUMENT
  # ## AGAINST IT
  #
  # None of VS Code Web, Gitpod, Cloud9, StackBlitz or CodeSandbox binds an
  # unmodified letter to a stepping command. That is a real finding and it has
  # a single, sufficient explanation: every one of them is an EDITOR, and in an
  # editor a bare letter is text. It says nothing about a read-only surface.
  #
  # The product that IS in this category does bind them. `Debugger-UX-
  # Research.md` §3.2: "Walnut added `b` (step back), `n` (step into), `o`
  # (step over) as keyboard shortcuts" — a hosted, read-only transaction
  # debugger, which is precisely what this is.
  #
  # And the survey's other half is the stronger argument. No surveyed product
  # ships a named browser-safe keymap at all; their answers are per-platform
  # conditional defaults the user cannot see (VS Code), avoidance by never
  # binding the key (StackBlitz, CodeSandbox), silence (Cloud9), or "install it
  # as a PWA" (Gitpod and CodeSandbox both). A preset every chord of which
  # simply arrives is a gap in that field, not a departure from it.
  (daStepForward, chord("n")),
  (daStepBackward, chord("N")),
  (daStepIn, chord("s")),
  (daReverseStepIn, chord("S")),
  (daStepOut, chord("f")),
  (daReverseStepOut, chord("F")),
  (daContinue, chord("c")),
  (daReverseContinue, chord("C")),
]

const VsCodeBindings = [
  # VS CODE'S OWN SET, for the muscle memory of everyone who has debugged in
  # an editor — and the set that VS Code for the Web, github.dev, Gitpod and
  # every VS-Code-derived browser IDE ship unchanged.
  #
  # `F5` continue, `F10` step over, `F11` step into, `Shift+F11` step out —
  # read from `debugCommands.ts` in `microsoft/vscode`, which is also, verbatim
  # and byte-identical in the debug sections, `debugCommands.ts` in
  # `gitpod-io/openvscode-server`. So this one table is what VS Code desktop,
  # vscode.dev, github.dev and Gitpod's browser IDE all bind.
  #
  # THE REVERSE MOVES TAKE `Alt`, and they have to come from somewhere else
  # because VS Code has no reverse moves to copy. `Alt` is chosen over a second
  # `Shift` because `Shift+F11` is already Step Out in this set — the desktop
  # app's "Shift means backwards" rule is not available here without colliding
  # with the very set being reproduced. This is the cost of adopting a keymap
  # designed for a debugger that only goes forwards.
  #
  # WHAT THIS PRESET COSTS, stated because the survey says every one of these
  # is a known, live problem in the products that ship them:
  #
  #   * `F11` is fullscreen. VS Code substitutes `Alt+F11` — but ONLY under
  #     `isWeb && isWindows`, with the source comment "Windows browsers use F11
  #     for full screen, thus use alt+F11 as the default shortcut". Mac and
  #     Linux browser users get bare `F11` and the collision.
  #   * `F5` is reload, and VS Code Web has this OPEN as a bug rather than
  #     fixed (microsoft/vscode#187440, milestone Backlog).
  #
  # Both are reported per row by `hazardOf` rather than summarised here, and
  # the preset is offered anyway: a visitor who has already configured their
  # machine for these keys should get the bindings they know. Refusing to offer
  # them would be deciding for them — but offering them silently would be the
  # CodeSandbox founder's objection, stated on their own tracker about this
  # exact class of choice: "No use of keybindings that don't work."
  (daContinue, chord("F5")),
  (daReverseContinue, chord("F5", alt = true)),
  (daStepForward, chord("F10")),
  (daStepBackward, chord("F10", alt = true)),
  (daStepIn, chord("F11")),
  (daReverseStepIn, chord("F11", alt = true)),
  (daStepOut, chord("F11", shift = true)),
  (daReverseStepOut, chord("F11", shift = true, alt = true)),
]

const DesktopBindings = [
  # CODETRACER'S DESKTOP SET, verbatim from `GUI/Keyboard-Shortcuts-System.md`:
  #
  #     forwardContinue F8    reverseContinue SHIFT+F8
  #     forwardNext     F10   reverseNext     SHIFT+F10
  #     forwardStep     F11   reverseStep     SHIFT+F11
  #     forwardStepOut  F12   reverseStepOut  SHIFT+F12
  #
  # It is offered for continuity with the desktop application — `Front-End-
  # Architecture.md` §"Keyboard model" asks that BlockTracer follow the desktop
  # shortcuts "so muscle memory carries" — and it is the preset with the most
  # hazard, which the dialog says row by row rather than this comment saying
  # once. `F12` in particular cannot be delivered to a page in any mainstream
  # browser; a visitor who selects this preset is told that about that row.
  (daContinue, chord("F8")),
  (daReverseContinue, chord("F8", shift = true)),
  (daStepForward, chord("F10")),
  (daStepBackward, chord("F10", shift = true)),
  (daStepIn, chord("F11")),
  (daReverseStepIn, chord("F11", shift = true)),
  (daStepOut, chord("F12")),
  (daReverseStepOut, chord("F12", shift = true)),
]

func keymapOf*(id: KeymapId): Keymap =
  ## The bindings in force for a preset.
  ##
  ## `kmNone` returns an EMPTY binding list, and that is not a degenerate case
  ## to be tidied away — it is the value the pre-hydration page renders with.
  ## See `controlLabel` below: a page that has not bound a key must not name
  ## one, and the way that is guaranteed is that the served frame is rendered
  ## against a keymap that has none.
  result.id = id
  case id
  of kmNone: discard
  of kmLetters:
    for (a, c) in LettersBindings: result.bindings.add Binding(action: a, chord: c)
  of kmVsCode:
    for (a, c) in VsCodeBindings: result.bindings.add Binding(action: a, chord: c)
  of kmDesktop:
    for (a, c) in DesktopBindings: result.bindings.add Binding(action: a, chord: c)

const DefaultKeymapId* = kmLetters
  ## What an anonymous visitor who has chosen nothing gets.
  ##
  ## The letters, because they are the only preset every chord of which
  ## actually reaches the page on every platform this product is used on. A
  ## default that a Mac silently eats would reproduce, as a default, exactly
  ## the defect this whole change exists to fix.

func presetName*(id: KeymapId): string =
  ## What the preset is called in the dialog.
  case id
  of kmLetters: "Letters"
  of kmVsCode: "VS Code"
  of kmDesktop: "CodeTracer desktop"
  of kmNone: "None"

func presetWhy*(id: KeymapId): string =
  ## One sentence saying who each preset is FOR.
  ##
  ## A preset picker with four bare names makes the visitor guess, and the
  ## thing they most need to know — that three of these four contain keys their
  ## platform may intercept — is exactly what a name cannot carry.
  case id
  of kmLetters:
    "Single keys, no modifiers. Every chord reaches the page on every platform."
  of kmVsCode:
    "The editor bindings, for muscle memory. Uses function keys."
  of kmDesktop:
    "What the CodeTracer desktop app binds. Uses function keys."
  of kmNone:
    "No stepping shortcuts. The toolbar buttons still work."

func parseKeymapId*(s: string): KeymapId =
  ## A stored value back into a preset, tolerantly.
  ##
  ## An unrecognised string is the DEFAULT rather than an error, which is
  ## `Configuration.md` §4's "forward compatible" rule applied at the field
  ## level: "An older build encountering a newer `bt.version` resets to
  ## defaults rather than misinterpreting." A build that has never heard of a
  ## preset a newer build wrote must not leave the visitor with no chords at
  ## all.
  for id in KeymapId:
    if $id == s: return id
  DefaultKeymapId

func actionFor*(km: Keymap; c: Chord): (bool, DebugAction) =
  ## Which move this key press is, if it is one.
  ##
  ## The dispatcher's half of the table. Returns a found-flag rather than an
  ## `Option` because this is on the JS target's key path and `options` would
  ## be an import for one bit.
  for b in km.bindings:
    if b.chord == c: return (true, b.action)
  (false, daStepForward)

func chordFor*(km: Keymap; a: DebugAction): (bool, Chord) =
  ## The chord for a move, if the keymap binds one.
  ##
  ## The tooltip's half of the same table. The pairing is the invariant: a
  ## tooltip can only obtain a chord from the structure the dispatcher matches
  ## against, so a displayed chord is a bound chord by construction rather than
  ## by anybody remembering to keep two lists equal.
  for b in km.bindings:
    if b.action == a: return (true, b.chord)
  (false, Chord())

func describe*(c: Chord): string =
  ## A chord as a reader sees it.
  ##
  ## `Shift` is printed for the function keys, where it is a real modifier bit,
  ## and NOT for letters, where the capital already is the shift — printing
  ## "Shift+N" for a chord whose `key` is `"N"` would name two key presses for
  ## one, and a visitor who then pressed Shift and N would be right and the
  ## tooltip wrong about why.
  var parts: seq[string]
  if c.ctrl: parts.add "Ctrl"
  if c.alt: parts.add "Alt"
  if c.meta: parts.add "Cmd"
  if c.shift: parts.add "Shift"
  parts.add c.key
  parts.join("+")

func hazardOf*(c: Chord; mac: bool): Hazard =
  ## What the platform does to this chord before the page can see it.
  ##
  ## COMPUTED, never stored. A preset lists chords; whether a chord survives
  ## its journey to the document is a property of the key and the platform, and
  ## a preset that carried its own answer could claim a key was safe that this
  ## function knows is not.
  ##
  ## `F11` and `F12` are browser-reserved on every desktop browser this
  ## product targets: fullscreen and developer tools respectively, both
  ## consumed above the page. `Shift` does not rescue them — `Shift+F12` is
  ## still routed to the browser in Chrome and Firefox — so the modifier is not
  ## consulted for those two keys.
  ##
  ## On macOS the whole `F1`–`F12` row is media and Mission Control by default,
  ## which is a WEAKER statement than browser-reserved: the visitor can change
  ## it in System Settings, or hold `Fn`. So it is a different hazard with a
  ## different sentence, and the dialog prints them differently.
  if c.key.len >= 2 and c.key[0] == 'F' and c.key[1] in {'0'..'9'}:
    # F11 and F12 are consumed above the page. Microsoft's own debug team says
    # so of F11 in as many words, on a pull request about this exact binding:
    # "it's a browser feature and we can't override" (microsoft/vscode#75807).
    if c.key == "F11" or c.key == "F12": return hzBrowserReserved
    # F5 IS deliverable — it is reload, and reload is preventable. It is
    # flagged anyway because the habit is near-universal and the surprise is
    # expensive: a visitor who presses F5 expecting a refresh and gets a
    # `continue` has lost their place. VS Code's web build has this filed as an
    # open bug rather than fixed (microsoft/vscode#187440: "F5 in browsers is a
    # fairly common shortcut for refresh. I think it should not be used to
    # start debugging on web"), which is precisely the state of affairs a
    # visitor is owed a sentence about rather than a silent default.
    #
    # Checked BEFORE the macOS branch: on a Mac, F5 is both a function-row key
    # and the reload habit, and the reload habit is the one that costs the
    # visitor their position.
    if c.key == "F5": return hzShadowsBrowser
    # The rest of the function row is deliverable to a page — measured by
    # someone else, at some cost. VS Code Web shipped `Alt+F10` for Step Over
    # on the belief that "Browsers do not allow F10 to be binded"
    # (microsoft/vscode#181792), and then reverted it to plain `F10`:
    # "This turned out to be incorrect, so we make the shortcut consistent
    # (F10) with desktop VSCode" (microsoft/vscode#183510). So F8 and F10 reach
    # the page, and the only thing standing between them and the visitor is the
    # Mac's function-key preference.
    if mac: return hzMacFunctionKey
  hzNone

func hazardText*(h: Hazard): string =
  ## The sentence the dialog prints beside a row. Empty when there is nothing
  ## to say, so the caller renders nothing rather than "None".
  case h
  of hzNone: ""
  of hzBrowserReserved:
    "your browser takes this key before the page can see it"
  of hzMacFunctionKey:
    "a media key on this Mac unless you hold Fn, or turn on " &
      "\"Use F1, F2, etc. keys as standard function keys\""
  of hzShadowsBrowser:
    "this is also your browser's reload — the page takes it here"

func controlLabel*(a: DebugAction; km: Keymap): string =
  ## What the control is CALLED, with the key that works — the one string that
  ## feeds `title` and `aria-label`.
  ##
  ## ## THE INVARIANT THIS OVERLOAD EXISTS TO MAKE STRUCTURAL
  ##
  ## A chord cannot be displayed without being bound. Not "must not be" as a
  ## rule someone follows — cannot be, because the only way to obtain the text
  ## is `chordFor`, and `chordFor` reads the same `bindings` sequence that
  ## `actionFor` dispatches from. There is no literal to go stale.
  ##
  ## That is the defect this is written against, and it is a real one in the
  ## sibling product rather than a cautionary tale: §10.5 records two spec
  ## documents already disagreeing about `Shift+F5`, and notes that "a tooltip
  ## that lies about a key is worse than a tooltip that is absent, because the
  ## visitor tries the key, nothing happens, and what they learn is that the
  ## shortcuts do not work."
  ##
  ## ## AND WHY THE SERVED PAGE PASSES `kmNone`
  ##
  ## The pre-hydration frame has no bundle, therefore no `keydown` handler,
  ## therefore no chord — and it renders through this same proc. If it were
  ## given a real keymap it would print keys that nothing on that page listens
  ## for, which is precisely the "tooltip naming a chord that does not fire"
  ## this change exists to avoid, arriving on the one build that cannot fire it.
  ##
  ## So the default is `kmNone` and hydration passes the live keymap. It is the
  ## same discipline `renderControls` already applies to the scrubber, in its
  ## own words: the `role="slider"` is stamped by `markScrubberSeekable` "in the
  ## one compilation that also implements the gesture", because "a
  ## `role="slider"` on the crawled artefact would be a control that announces
  ## a range it cannot be moved along". A chord in a tooltip on that same
  ## artefact is the identical mistake in a different attribute.
  let name = controlLabel(a)
  let (bound, c) = km.chordFor(a)
  if not bound: name
  else: name & " (" & describe(c) & ")"
