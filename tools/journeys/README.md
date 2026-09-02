# Journey conformance

Each journey is a sentence from the spec — *"a visitor who opens X sees Y"* —
asserted by loading the artefact CI deploys in a real browser and reading what
is on the screen.

```
just journeys-engine      # once: fetch the 18 MB replay engine into the cache
just journeys-build       # build the deployed shape, then run the journeys
just journeys-deployed    # the same, over `nix build .#default` itself
just journeys-selftest    # do the journeys bite? one mutation per named assertion
```

Runs in CI as the **`journeys`** job in `.github/workflows/ci.yml`, on
`eph-linux-x64`, over `nix build .#default` — the same artefact
`deploy-cloudflare-pages.yml` uploads, staged the same way, with the replay
engine copied to its own origin by the same script.

## Why this exists

Every other check in this repository asserts one component's contract: the route
classifies, the renderer emits the class, the exporter round-trips, the tokens
resolve. Four user-visible defects passed all of them, because **no check
anywhere stated an end-to-end claim**.

The clearest case is in the sibling repository. A suite literally named
`test_every_entry_form_reaches_the_application` proves every URL form
*classifies*; `currentEntryRequest()`, the function that would consult the
classifier at run time, has **zero callers**. Nothing noticed, because no test
asserted that a visitor at a URL gets anything.

So a journey here may not assert a component's contract. It asserts what a
visitor sees, and it fails whichever layer broke.

## The five rules, and where each came from

1. **Drive the artefact a visitor loads.** `just export` ships zero JS;
   `flake.nix packages.default` ships the hydration bundle, and on the debug
   route **the two disagree**. `lib/site.mjs` refuses a tree that is not the
   deployed shape, with exit 2 rather than a verdict.

2. **Assert the artefact, never a chain of successes.** A DAP server once
   answered `success: true` to four requests over a session with no trace open
   (Verification-Harness-Traps.md §2). Journey 03 is written against the local
   form: a step that advances the URL and moves nothing on the screen. The URL
   is a *control*, never the verdict.

3. **A test whose subject can be empty passes vacuously.** `Journey.subjects()`
   is the required first call of anything that quantifies, and `countIs` is the
   verb wherever membership is knowable — an "at least one" control is satisfied
   by one member of five (§4b).

4. **Do not build on fixtures that supply the answer.** 115 debug-route cases
   survived a defect because the fixture set the position they verified. **No
   journey names a file, a line, a step, a chain or a transaction.** Every
   subject is selected by a property read off the tree, and every expectation is
   a relation between two things the page reports.

5. **Prove the instrument, then judge the subject.** Arm I runs before any
   product page is loaded: the same server, the same browser and the same probe
   over two hand-written fixtures, one with a sentence and one empty. A browser
   that cannot lay out text exits 2 without judging anything. The sibling
   repository's mount gate blocked a deploy over a byte-perfect page because its
   runner's Chromium had no fonts.

## Rendered, not present

The source pane holds every file in the bundle at once and hides all but one
with CSS (`:target` tabs, so the session stays navigable with scripting off).
`.srcline` therefore counts lines that **exist**, most of them `display:none`.

An earlier draft read the first `.srcline` in document order, reported
`[package]` — the hidden `Nargo.toml` — and called a correct page broken. Every
assertion here goes through `checkVisibility`. A gate that cries wolf gets
switched off, and then it is not there for the real one.

## Visible is not the same claim as still

A visitor reported that stepping scrolled the source pane on every step and
pinned the position to the pane's top edge. Journeys 03, 06 and 09 were green
throughout, and correctly so — they assert that the position is **rendered**, and
it was. `the marked line is on screen` is true when the line is glued to the top
edge and true when it is properly revealed, so a journey written that way would
have printed GREEN over the reported behaviour and certified it.

**A complaint about movement is not answerable by an assertion about presence.**
Journey 12 asserts where the *pane* is, and two readings are needed rather than
one, because the defect had two mechanisms:

- `scrollTop` catches a pane that re-scrolls on every step.
- **The position's distance from the top of the box** catches the other half, and
  nothing else does. The bundle used to re-window the document on every stop, so
  the position sat at row 7 of a listing rebuilt beneath it — `scrollTop` was 0
  before and 0 after, every journey stayed green, and the pane moved under the
  reader on every step. Measured with that half restored as a selftest arm, the
  position stands at 189px from the top for twenty-three consecutive steps while
  every other assertion in this directory passes.

Two smaller rules came out of the same file and generalise:

- **Read the scroller you find, not the one you name.** `#pane-editor .panebody`
  is the element the product's own code holds and it is *not* where the source
  pane overflows — `.src` is. On the demo pane `.panebody` has a scroll range of
  zero. A journey that read it would have measured a constant, and a constant
  supports whichever assertion its author wants. `sourceScroll` walks out from the
  marked line and takes the first ancestor that actually scrolls, and asserts that
  it found one with somewhere to go before judging that it stayed put.
- **A walk stops when the trace does.** A fixed thirty steps clicked seventeen
  times at a recording with thirteen left and entered every non-step as a step
  during which nothing moved — reporting a working product as broken. The length
  of the walk is asserted against a floor instead.

## The ledger

`ledger.json` names the journeys known RED on this branch, each with what was
measured and what closes it. A ledgered journey **still runs and still prints
every failed assertion**; what the entry does is stop the exit code from
blocking other branches on a defect that is already stated.

**It fails in both directions.** A ledgered journey that goes GREEN fails the
run, so an entry cannot outlive its defect: whoever lands the fix is told, by
name, to delete the line.

## The corpus, and the capability seam

`lib/corpus.mjs` discovers every transaction from the exported tree. Nothing is
listed by name — `tools/capture/check-coverage.mjs` already learned why: *"A
list cannot notice a chain nobody added it to."*

The demo chain is being rebuilt into a suite of purpose-built Noir programs, one
per capability. `capabilityManifest()` / `capabilitiesOf()` are the seam: when
the corpus ships its manifest they start returning real answers and a journey
can select "the transaction that demonstrates loops". Until then they return an
empty set — so a journey written against a capability finds no subjects and
**fails its `subjects()` call** rather than passing over nothing.

Two asymmetries to assert rather than paper over when parity journeys arrive: a
chain trace is rung 3 (no source, no names) while a demo trace is source-level —
journeys 01 and 05 already split on exactly that, and the split is the finding;
and BlockTracer has no origin-chain surface at all, so a cross-consumer parity
claim cannot be "the three agree everywhere". Where they cannot agree, the
difference is the assertion.

## What is NOT claimed

- **No deployed hostname is driven.** Everything runs over a loopback server
  serving the built tree. A journey against `blocktracer.org` would be a
  different claim about a different thing (DNS, CDN, cache rules) and is not
  made here.

  **This exclusion has already cost a user-visible defect, so it is worth being
  precise about what it leaves open.** A visitor reported that the position
  marker was missing and did not follow the rows they clicked. Every journey on
  `dev` was green, and `dev` was genuinely correct: the same tree, the same
  engine and the same browser move the mark to the row's step. The site was
  serving an `assets/hydrate.js` older than `dev` — 1,162,553 bytes against
  `dev`'s 1,168,994 — that predated both fixes recorded in `ledger.json`'s
  `_closed`, and on it the two defects those entries describe reproduced
  verbatim: 0 lines marked after hydration, `data-step` pinned at 128, `?t=` and
  the recovery anchor advancing on every click.

  Isolating it is a two-line experiment, and it is how journey 09's red arm was
  obtained: build the tree, replace `client/dist/assets/hydrate.js` with the one
  the deployed origin serves, and re-run. Nothing else changes, so whatever
  reddens is the bundle. **A green run here means the artefact `nix build`
  produces is correct. It says nothing whatsoever about which artefact is
  currently served**, and that gap is not the ledger's to hold — a ledger entry
  describes a defect in this repository, and this one was not in it.
- **Nothing judges the `codetracer` product.** Two of the four seed defects
  belong to it; see the landing report for why they could not be asserted on
  that repository's `dev`.
- **Nothing here measures pixels.** `tools/capture/` owns that and asserts
  byte-identity between two runs; this clicks things, which would invalidate
  that claim. Separate jobs, deliberately.
- **The stepping journeys skip without the replay engine, and a skip is not a
  pass.** It is counted, reported, and fails the run.
