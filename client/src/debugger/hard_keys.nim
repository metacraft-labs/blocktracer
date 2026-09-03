## The keys the bundle claims WITHOUT going through `keymap.nim` — read out of
## the source that claims them, at compile time.
##
## ## WHY THIS FILE EXISTS: A LIST OF SHORTCUTS THAT OMITS THESE IS LYING
##
## `keymap.nim` is the one table for the stepping chords, and `ScrubKeys` is
## the one table for the scrubber's arrows. Between them they are the whole of
## what a reader would call "the shortcuts", and the shortcuts dialog renders
## exactly them. But they are not the whole of what the page does with a key
## press. `hydrate.nim` also claims keys directly, as string literals, in two
## places that no table knows about:
##
##   * `activationKey` — `Enter`, Space and the legacy `Spacebar` — which
##     presses the breakpoint gutter, because a `span` with `role="button"`
##     gets no synthetic click from either key.
##   * the `Escape` comparison in `bindShortcuts`, which closes the dialog
##     before the stepping dispatcher looks at the press at all.
##
## So there are THREE registries in which a key can be claimed on this
## surface — the keymap, the scrubber table, and these literals — and until
## this module only the first two were enumerated anywhere. A "full list of
## active shortcuts" drawn from the first two is not a small omission: it is
## the most useful-looking kind of wrong, because a reader consults it
## precisely to learn what a key will do, and it would answer confidently
## about the two registries while a third silently overrode them.
##
## The concrete failure it permits: a future preset binds `Escape` or Space to
## a move. Both tables stay internally consistent, the dialog draws a row for
## it, `actionFor` agrees the chord is bound — and the key does something else,
## because line 2127's Escape branch and the gutter's `activationKey` run
## first. The row would be true about the table and false about the browser.
##
## ## THE DERIVATION, AND WHY IT IS A DERIVATION
##
## `HardKeys` below is not a transcription of those literals. It is
## `staticRead` over `client/hydrate/hydrate.nim` — the file that makes the
## claims — parsed for the two syntactic forms that make them. Delete the
## Escape handler and `Escape` leaves this list without anyone editing this
## file; add a third claim and `DescribedKeys` no longer covers the derived
## set and the build stops.
##
## This is deliberately the shape CodeTracer's `ui/shortcut_labels.nim` uses
## for its own `hardBoundChords`, and for the same stated reason: a
## hand-copied chord list is the artefact that silently diverges. This
## campaign has already found one carrying a comment promising it would redden
## the day a particular bind was removed, which it did not.
##
## ## WHAT IS DERIVED AND WHAT IS NOT
##
## The KEY is derived; the SENTENCE describing what the key does is not, and
## cannot be — no parse of `if $keyName(ev) == "Escape":` yields "closes the
## shortcuts dialog". So the two are joined by a compile-time check instead:
## `DescribedKeys` must name exactly the derived set, no more and no fewer.
## A description may therefore go stale in its WORDING, which review catches,
## but the set it covers cannot go stale in its MEMBERSHIP, which review does
## not catch. That is the half worth mechanising.

import std/[os, strutils, algorithm]

const HydrateSource = staticRead(
  currentSourcePath().parentDir.parentDir.parentDir / "hydrate" / "hydrate.nim")
  ## The file that claims these keys, read at COMPILE time.
  ##
  ## `client/src/debugger` -> `client/hydrate`, the same `parentDir` walk
  ## `demo_session.nim` uses to reach `fixtures/`. Read at compile time for the
  ## reason stated there — nothing needs to exist beside the built binary — and
  ## additionally because a RUNTIME read could not fail the build, and failing
  ## the build is the entire mechanism here.

type
  HardKey* = object
    ## A key claimed outside the keymap, and what claims it.
    key*: string
      ## `KeyboardEvent.key` verbatim, exactly as `Chord.key` spells one, so
      ## the two registries can be compared without a normalisation step that
      ## could itself be wrong. Space is `" "`.
    what*: string
      ## What the page does with it. Rendered to a reader; see the note above
      ## on why this half is written rather than derived.

func literalsAfter(hay, marker: string; within: Slice[int]): seq[string] =
  ## Every `marker"…"` literal inside `within`.
  ##
  ## ANCHORED ON THE COMPARISON, not on "the next quoted thing". The first
  ## version of this scanned for bare `"` after an opener and collected the
  ## `"""` of the `importjs` pragma and three fragments of JavaScript — it
  ## produced a five-element list of garbage, and the covering check below is
  ## what said so. Matching `e.key === "` and `$keyName(ev) == "` means the
  ## only strings collected are ones being COMPARED AGAINST A KEY, which is
  ## exactly the claim being enumerated.
  ##
  ## Deliberately a scanner over source text rather than a Nim parse: what is
  ## being checked is that a claim in `hydrate.nim` is REPRESENTED here, and a
  ## scanner a change can defeat only by removing an asserted anchor is
  ## sufficient — defeating it fails the build rather than emptying the list.
  var i = within.a
  while i < within.b:
    let at = hay.find(marker, start = i)
    if at < 0 or at >= within.b: break
    let s = at + marker.len
    let e = hay.find('"', start = s)
    if e < 0 or e > within.b: break
    result.add hay[s ..< e]
    i = e + 1

func derivedHardKeys(): seq[string] =
  ## The claimed keys, read out of `hydrate.nim`.
  ##
  ## TWO FORMS, because the file makes its claims in two ways and a scanner
  ## that knew only one would report a clean list while missing half of it.

  # FORM 1: the `activationKey` FFI body — `e.key === "Enter" || …`. Bounded to
  # the pragma: it starts at the proc and ends at the `""".}` that closes the
  # `importjs`, so the scan cannot run on into the doc comment beneath it, nor
  # into any later `e.key ===` that a different FFI proc might introduce.
  let aStart = HydrateSource.find("proc activationKey(ev: Event): bool")
  if aStart >= 0:
    var aEnd = HydrateSource.find("\"\"\".}", start = aStart)
    if aEnd < 0: aEnd = HydrateSource.len
    for k in literalsAfter(HydrateSource, "e.key === \"", aStart .. aEnd):
      if k notin result: result.add k

  # FORM 2: direct comparisons, `$keyName(ev) == "Escape"`, anywhere in the
  # file. Every occurrence, not the first — a second such branch is exactly
  # the addition this module exists to notice.
  for k in literalsAfter(HydrateSource, "$keyName(ev) == \"", 0 .. HydrateSource.len):
    if k notin result: result.add k

  result.sort()

const DerivedKeys* = derivedHardKeys()

# THE ANCHORS. `extractQuoted` returns an empty sequence for an opener it
# cannot find, so a rename in `hydrate.nim` would empty this list SILENTLY and
# every check below would pass over nothing — the failure mode this whole
# module is written against, reproduced inside the mechanism meant to prevent
# it. These turn that into a build error.
static:
  doAssert "proc activationKey(ev: Event): bool" in HydrateSource,
    "hard_keys: the `activationKey` anchor is gone from hydrate.nim. The keys " &
    "it claimed are no longer being derived — re-point the scanner rather " &
    "than letting the list quietly shrink."
  doAssert "$keyName(ev) == \"" in HydrateSource,
    "hard_keys: no direct key comparison found in hydrate.nim. Either the " &
    "form changed or the claims moved; either way the derived list is now " &
    "silently incomplete."
  doAssert DerivedKeys.len >= 2,
    "hard_keys: derived " & $DerivedKeys.len & " claimed keys, which is fewer " &
    "than the two forms can honestly produce."

const DescribedKeys*: seq[HardKey] = @[
  # Sorted the way `DerivedKeys` is, so the covering check below reads as a
  # comparison of two lists rather than of two sets in different orders.
  HardKey(key: " ",
          what: "Set or clear a breakpoint on the focused gutter line"),
  HardKey(key: "Enter",
          what: "Set or clear a breakpoint on the focused gutter line"),
  HardKey(key: "Escape",
          what: "Close the keyboard shortcuts dialog"),
  HardKey(key: "Spacebar",
          what: "Set or clear a breakpoint on the focused gutter line"),
]

static:
  # EXACT COVERAGE, both directions, and each direction catches a different
  # mistake. A derived key with no description is a claim this page would omit
  # from its list; a description with no derived key is a row the page would
  # show for behaviour that no longer exists. The second is the one that
  # survives ordinary review, because a stale row still renders.
  var described: seq[string] = @[]
  for h in DescribedKeys: described.add h.key
  described.sort()
  doAssert described == DerivedKeys,
    "hard_keys: the described set and the set derived from hydrate.nim have " &
    "drifted.\n  derived:   " & $DerivedKeys & "\n  described: " & $described &
    "\nA key claimed in hydrate.nim must be described here, and a key " &
    "described here must still be claimed there."

func hardKeys*(): seq[HardKey] =
  ## The claimed keys with their descriptions, for a surface that lists them.
  DescribedKeys

func hardClaim*(key: string): (bool, string) =
  ## Does something outside the keymap already claim `key`, and what?
  ##
  ## This is the question a preset has to be able to ask. `key` is compared
  ## verbatim against `Chord.key`, which is why `HardKey.key` stores the
  ## browser's spelling rather than a prettified one.
  for h in DescribedKeys:
    if h.key == key: return (true, h.what)
  (false, "")
