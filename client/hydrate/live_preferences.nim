## What the visitor has chosen, where it is kept, and the seam the account tier
## drops into.
##
## ## THE FIRST `localStorage` IN THIS REPOSITORY, and why that sentence needed
## ## checking rather than repeating
##
## `live_breakpoints.nim` carries a long note ending "the first
## `localStorage.setItem` in this repository is not a convenience, it is the
## moment §12's claim that a visitor 'chooses nothing that affects where a byte
## comes from' acquires an exception". That note is about BREAKPOINTS, and it
## is right about breakpoints. It is worth being precise that it does not
## transfer to this file, because the reasoning it gives is specific:
##
##   * A breakpoint set is a record of what a visitor was INVESTIGATING. That
##     is a privacy surface — §10.8 calls it "a privacy-surface decision
##     wearing a debugger feature's clothes" — and it is why that decision was
##     deferred rather than taken by whichever feature needed it first.
##   * A keymap preset is one enum out of four. It records nothing about what
##     was looked at, contains no identifier, names no trace, and is the same
##     value for every visitor who picks it.
##
## And it is not an exception to §12 at all. §12's claim is about WHERE A BYTE
## COMES FROM, and `Configuration.md` §6.1 states the rule in force: "No
## preference, and no URL parameter, may change where bytes come from. The
## resolution chain governs PRESENTATION only." Which key steps the session is
## presentation in the strictest available sense.
##
## Nor is this scheme invented here. `Configuration.md` §4 already specifies
## it, down to the field: preferences are "stored in `localStorage`, namespaced
## `bt.*`, migrated by version", and the sample object it prints contains
## `"bt.ui": { … "keymap": "default" … }`. This file implements that section;
## it does not decide it.
##
## ## ONE INTERFACE, ONE IMPLEMENTATION, AND THE VALUE IN THE MIDDLE
##
## Configuration lives in the account when the visitor is signed in and in
## local storage when they are anonymous, and creating an account moves the
## anonymous configuration online. Only the anonymous half is built here, and
## the shape is what makes the other half cheap rather than a rewrite:
##
##   * `ClientPreferences` is a plain VALUE. Not a handle, not a cursor over
##     storage — an object that can be read out of one store, held, and handed
##     to another. That is the entire migration: `let p = local.load(); account.save(p)`.
##   * `PreferenceStore` is the interface, with proc fields rather than
##     methods, because the account implementation is a different backing
##     store and not a subclass of this one.
##   * NOTHING ELSE IN THE CLIENT CALLS `localStorage`. If a view reaches for
##     the browser API directly, the account tier acquires a second place to
##     be wired and the migration stops being one line. That is the constraint
##     this module exists to hold, and it is the reason `getItem`/`setItem`
##     below are private.

import std/[json, strutils]
import ../src/debugger/keymap

type
  ClientPreferences* = object
    ## Everything a visitor has chosen. One value, serialisable, movable.
    ##
    ## `version` is `Configuration.md` §4's `bt.version`, carried IN the value
    ## rather than read separately, so that a preferences object handed to
    ## another store carries its own schema generation with it.
    version*: int
    keymap*: KeymapId

  PreferenceStore* = object
    ## Where a `ClientPreferences` is kept.
    ##
    ## Proc fields, so a second implementation is a second constructor and
    ## needs no change here or at any call site. The account-backed store is
    ## the same two procs over a network round trip.
    ##
    ## Neither proc can fail outward. A store that cannot be read yields
    ## defaults and a store that cannot be written drops the write — see
    ## `localPreferenceStore` for why that is the right shape rather than an
    ## evasion.
    load*: proc(): ClientPreferences {.closure.}
    save*: proc(p: ClientPreferences) {.closure.}

const PreferencesVersion* = 1
  ## `Configuration.md` §4's `bt.version`. Bumped when a stored shape changes
  ## meaning; a stored value from a LATER version is discarded, per §4's
  ## "forward compatible" rule.

const
  VersionKey = "bt.version"
  UiKey = "bt.ui"
  KeymapField = "keymap"

func defaultPreferences*(): ClientPreferences =
  ## What a visitor who has chosen nothing has.
  ClientPreferences(version: PreferencesVersion, keymap: DefaultKeymapId)

# ---------------------------------------------------------------------------
# The browser API, wrapped once and kept private
# ---------------------------------------------------------------------------
#
# BOTH OF THESE ARE `cstring`, AND THAT IS THE BUG THAT ATE A DAY.
#
# `hydrate.keyName` was declared `{.importjs.}` returning `string` for a proc
# that returns a JavaScript string. Nim's `string` and JS's string are not the
# same object on this target: the compiler emitted code that walked the JS
# string as if it were a Nim seq of character codes, every comparison fell
# through, and NOTHING RAISED — every key silently did nothing, which is
# indistinguishable from "no handler is attached". A whole class of "keys do
# not work in the browser" findings had that as its cause.
#
# So every `importjs` in this file that returns a JS string is typed `cstring`
# and converted with `$` at the boundary, once, deliberately.
#
# AND BOTH ARE TOTAL. `localStorage` is not merely absent in some
# configurations, it THROWS on access: Safari in Lockdown Mode and every
# browser with third-party storage blocked raise a `SecurityError` from the
# property getter itself, before any method is called. A visitor in that state
# must get a working debugger with default chords, not a page that fails to
# hydrate — so the try/catch is in the JS, around the property access, and the
# failure is spelled as "no value".

proc rawGetItem(key: cstring): cstring {.importjs: """
  (function(k){ try { return window.localStorage.getItem(k) || ''; }
                catch (e) { return ''; } })(#)""".}
  ## The stored string, or "" for absent, unreadable, or unavailable.
  ##
  ## The three are deliberately ONE answer. A caller that could tell them apart
  ## would be tempted to report the difference to the visitor, and "your
  ## browser is blocking storage" is a sentence this product would then have to
  ## be able to write truthfully in four browsers' worth of conditions. The
  ## behaviour in every one of those states is identical — defaults, working
  ## keys, nothing persisted — so there is nothing for the distinction to
  ## change.

proc rawSetItem(key, value: cstring) {.importjs: """
  (function(k,v){ try { window.localStorage.setItem(k, v); }
                  catch (e) { } })(#, #)""".}
  ## Store, or silently do not.
  ##
  ## A write can fail for reasons that have nothing to do with this value —
  ## quota exhausted by another origin's use of the same box, storage disabled,
  ## private mode. None of them is worth interrupting a debugging session over,
  ## and none of them is actionable by the visitor from inside this dialog. The
  ## preference is applied to the live session either way; what is lost is only
  ## that it survives a reload.

proc localPreferenceStore*(): PreferenceStore =
  ## The anonymous tier: `localStorage`, namespaced `bt.*`, per
  ## `Configuration.md` §4.
  ##
  ## ## UNKNOWN FIELDS UNDER `bt.ui` ARE PRESERVED, and this is not fastidious
  ##
  ## §4's `bt.ui` holds `theme`, `layout`, `keymap` and `density` — four
  ## preferences owned by four features that will not ship together. A store
  ## that wrote `{"keymap": …}` wholesale would DELETE a theme the visitor had
  ## set, and the deletion would be invisible until they noticed their theme
  ## had reverted and blamed the debugger. So a write reads the object, sets
  ## one field, and writes it back.
  ##
  ## The same is true across builds: a newer build's field, written before the
  ## visitor loaded this one, survives a save from here.
  result.load = proc(): ClientPreferences =
    result = defaultPreferences()
    # THE VERSION GATE FIRST, and it fails toward defaults in both directions.
    # §4: "An older build encountering a newer `bt.version` resets to defaults
    # rather than misinterpreting." A missing version is the same answer — it
    # is either a fresh visitor or a box written by something that is not this
    # scheme, and neither is a value to parse.
    let stored = $rawGetItem(VersionKey)
    if stored.len == 0: return
    var v = 0
    try: v = parseInt(stored.strip()) except CatchableError: return
    if v != PreferencesVersion: return
    let uiRaw = $rawGetItem(UiKey)
    if uiRaw.len == 0: return
    var ui: JsonNode
    # A JSON parse over a value another origin's script, an extension, or a
    # half-finished write could have left behind. It is not trusted to be JSON
    # at all, let alone to be an object — `parseJson` raises on the first and
    # `kind` answers the second, and either way the visitor gets defaults and
    # a working keyboard.
    try: ui = parseJson(uiRaw) except CatchableError: return
    if ui.kind != JObject: return
    if KeymapField notin ui: return
    let f = ui[KeymapField]
    if f.kind != JString: return
    # `parseKeymapId` is tolerant BY DESIGN — an unrecognised preset name is
    # the default, not an error. See its own note: a build that has never heard
    # of a preset a newer build wrote must not leave the visitor with no chords.
    result.keymap = parseKeymapId(f.getStr())

  result.save = proc(p: ClientPreferences) =
    var ui = newJObject()
    let existing = $rawGetItem(UiKey)
    if existing.len > 0:
      try:
        let parsed = parseJson(existing)
        if parsed.kind == JObject: ui = parsed
      except CatchableError: discard
    ui[KeymapField] = %($p.keymap)
    rawSetItem(VersionKey, cstring($p.version))
    rawSetItem(UiKey, cstring($ui))
