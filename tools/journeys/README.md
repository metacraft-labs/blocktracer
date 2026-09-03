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

## A guard must be a fact the defect cannot reach

Rule 3 says a test whose subject can be empty passes vacuously. There is a
sharper version of it, and it cost this directory an assertion that ran green and
empty for the whole life of the journey that made it.

Journey 06 asserted *"a session that reports a position also shows one"* as an
implication guarded by `Number(live.facts.step) > 0`. The defect it existed to
catch was a session that landed at step 0 with **no playhead on 48 ticks** — so
the antecedent was false exactly when the defect was present. Worse, it was not
a historical accident: with the product correct, both of that journey's arms
still land at step 0, because the engine's `run-to-entry` parks there and says
so. `step > 0` was false on every subject, on every run.

**An implication is only as strong as its antecedent, and an antecedent nobody
asserts is one product change away from being false everywhere.** Three ways out,
in order of preference:

1. **Delete the implication.** Assert both halves unconditionally. Journey 06 now
   states that the served frame marks its position and draws its playhead on the
   tick its own step names, and that the live frame does too; "no state renders
   less than the pre-hydration page" is the conjunction, and there is no
   antecedent left to hide behind.
2. **Guard on a different artefact.** The served frame (`visitWithoutScript`), the
   export re-parsed with `DOMParser`, the worker wire read by an `addInitScript`
   instrument, or the manifest on disk — a hydration defect cannot move any of
   them. Journeys 07, 09, 11, 12, 13, 15, 17, 18 and 19 all use this and it is
   the pattern to copy.
3. **Lift the guard out and assert it as its own record.** Journey 13's
   `INSTRUMENT: the source pane has a scroller, so "it did not move" is a fact and
   not a vacuity`, and journey 12's `CONTROL: the sweep reads more than one cursor
   value`, are what this looks like.

Two smaller rules from the same sweep:

- **Put the subject count above the assertion, not elsewhere in the file.** The
  breakpoint journey's `countIs(gutterButtons, rows)` was `0 === 0` over a pane
  that had rendered nothing; the guard that caught it was thirty-five lines
  further down, so the journey went red while *that record* went green — and a
  mutation arm aimed at its text would have scored SURVIVED.
- **Choose a fallback so the degenerate case FAILS.** `markedNumber ?? 0` (falls
  out of the population), `-1` against `-2` (sentinels picked to be unequal), and
  `functionFirst ?? 0` (counted as a violation) are all correct. `?? ""` fed to
  `.includes()` is not, because `s.includes("")` is true of every string — which
  is how the call-trace journey's path check passed unconditionally against a
  `data-module=""`, the exact shape of the defect it was written for.

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
Journey 13 asserts where the *pane* is, and two readings are needed rather than
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
- **Where two mechanisms meet, assert the rule and not the outcome.** The source
  pane is opened at the position twice by two different things — `autofocus` plus
  a scroll margin on the served frame, the reveal policy on every stop after it —
  and journey 13 judges the one transition between them. The tempting assertion,
  *the hydrated landing keeps the served offset*, is **false**: the session does
  not land where the served frame stands (`shield.nr:32` → `main.nr:1` on the demo
  subject, step 128 → step 0 on a chain capture), so asserting it would have been
  a false RED against two correct changes. What is asserted is the policy's own
  rule applied to that transition — the pane leaves the served offset exactly when
  that offset no longer shows the position — with all three cases written and the
  one taken named in the transcript. `visitWithoutScript` exists for this single
  comparison: with the bundle running, the two mechanisms are indistinguishable by
  the time any probe can look.

## A suite that did not finish is not a suite that failed

`selftest.mjs` gives every ARM three verdicts — killed, survived, never-ran —
and gave ITSELF two. The third state it could reach and could not say is the one
it was observed in: dying part-way through the arm list with no `RESULT` line at
all. **A stall that produces no verdict reads to a human exactly like a suite
nobody bothered to run**, and it is the worse member of the family, because a
suite that never completes cannot tell you which of its arms are dead — which is
the only question it exists to answer. Every journey's green is unbacked for as
long as it is in that state. Two dead arms were found by hand rather than by
this file reporting them: `P4`'s `find` string occurred zero times after the
guard it names shed a conjunct, and `break-check.mjs`'s two markers had been
renamed out from under it.

Three mechanisms, in increasing order of how violent an ending they survive:

1. **Every exit path prints a `RESULT:` line.** `finish()` is the only thing
   that sets an exit code, and an `exit` handler prints `RESULT: DID NOT RUN` if
   nothing else did. The top-level `catch` used to print a stack and no verdict
   — which is how a missing `playwright` produced a log ending in an exception
   and no verdict at all.
2. **`SIGINT`/`SIGTERM`/`SIGHUP` are caught.** An agent's shell wrapper giving
   up at a timeout, a Ctrl-C, a CI cancellation. The handler prints the verdict
   *and restores the mutated file* — which a `finally` cannot, because it does
   not run when the process is signalled, and that is how
   `K/the-served-values-stand` was left in a worktree.
3. **A journal, `.selftest-journal.json`,** written before the first arm and
   rewritten after each one. `SIGKILL` and the OOM killer defeat 1 and 2 by
   construction, so the evidence has to be something already on disk. The NEXT
   run reads it and reports how far the last one got, by arm name and count.

The journal is never read to skip work. Its only purpose is to say that a
previous run did not finish, and where.

A **filtered** run (`--arm <substring>`) is a fourth case and is neither. It
exits 0, because landing one arm should not require re-proving sixty-one others,
but it prints `RESULT: OK OVER n OF m ARMS` — the full set is the suite's claim
and "OK" is the word someone quotes later.

## The suite does not fit in an hour, so it shards

Every run prints its wall clock broken down by journey. Each arm rebuilds the
tree and reruns its journey **three times** — before, mutated, restored — so the
cost is a journey's runtime times three, times the number of arms aimed at it,
and whether one journey dominates is a measurement rather than an argument.

Measured, warm tree, local builds:

```
  62 arms, ~115 minutes
  1017s  30%   3 arm(s)  339s/arm  the-timeline-can-be-dragged   ← 8 arms in full: ~45 min
   522s  15%   3 arm(s)  174s/arm  source-pane-holds-still-while-the-position-is-visible
   479s  14%   3 arm(s)  160s/arm  a-stepped-session-shows-the-values-it-is-at
```

`the-timeline-can-be-dragged` is about **39% of the whole suite** from one
journey, and it earns every second: two subject arms, three real drags each, and
a settle budget whose 6 s quiet window is measured against a chain seek observed
at 3.0 s. Shortening it is how the first draft of `settlePosition` came to report
three chain drags as landing on steps 7, 32 and 32 when the drop points were 259,
104 and 190. **The arms belong here** — journey 17 is where the drag is judged at
all, and a mutation suite that skipped the most expensive journey would be
certifying the cheap ones.

What does not follow is that the suite must run as one process. Things that run
it have wall-clock boxes: a run under an agent's background task was killed at
~60 minutes while running **arm 47 of 62**, printing no verdict — the reported
symptom, reproduced exactly. `--arm` cannot answer that, because it selects by
NAME and a name is not a budget.

```
just journeys-selftest-shard 1 4     # …and 2 4, 3 4, 4 4 — in any order, anywhere
just journeys-selftest-combine 4     # ONE verdict over the four journals
```

The slice is by **stride**, not by contiguous block: journey 17's eight arms are
adjacent in the list, so a contiguous shard would hold all of them and be the
whole problem again.

**`--combine` is not an OR of passes.** It fails unless the shards' arms, unioned,
are exactly the arm list — every arm once, none missing, none run twice, none
belonging to a version of the file that has since changed — and every one of them
killed. A shard that never ran leaves no journal, and the combine names it and
says `DID NOT RUN` rather than reporting a failure. "Three of four shards passed"
is not a claim about this suite; that is the same three-verdict rule, one level
up.

## The first complete pass, and what it found

Four shards, two at a time in two worktrees, `dfe7c98`:

```
  62 arm(s) over 4 shard(s): 57 killed, 3 survived, 2 never ran
    NEVER RAN  N/the-position-is-compared-by-number-alone
    NEVER RAN  O1/the-engine-never-gets-the-source
    SURVIVED   O4/the-control-does-not-say-what-it-would-answer
    SURVIVED   H/the-event-log-rows-are-not-bound
    SURVIVED   Z2/the-revealed-position-is-anchored-to-the-top
```

**These five are the point of the exercise, and none of them was visible before.**
The reason they had not been reported is not that anyone ignored them — it is that
the run producing them had never reached its summary. Each is now attributable:

* `N` — `NEVER RAN — the artefact is byte-identical to the unmutated one`. The
  mutation does not reach what the journey measures, so nothing about that
  assertion has been demonstrated either way. Not a survival, and reporting it as
  one would send someone to strengthen a test that may be fine.
* `O1` — `the assertion is ALREADY RED before the mutation`. Its journey,
  `a-value-can-be-traced-to-its-origin`, is red on `dev` and carries no ledger
  entry. A mutation cannot demonstrate anything about an assertion that was not
  green to begin with; this is the harness reporting the tree's state, not a
  defect in the arm.

  **AND THAT RED WAS NOT IN THIS REPOSITORY.** It was measured, at `8d1efe1a`,
  against one tree, one bundle and one corpus, with only the replay engine
  changed:

  | wasm | verdict |
  |---|---|
  | `cf79c4bf9854465b…` | **488 assertions, 22 green, 0 red, 1 ledgered red. `RESULT: OK`** — journey 07 green, 2 of 6 hops classified over 6 values |
  | `3009b9892fa181cf…` | 416 assertions, 11 green, **11 red** — journey 07 red, 0 hops over 0 values |

  The engine's own answer, asked on the worker's wire, was in nobody's
  transcript:

  ```
  CTFS from_bytes failed for "trace/trace.ct": new-format container advertises
  steps.dat but no seekable step stream could be opened; the container is
  inconsistent
  ```

  This corpus carries containers in two formats — `C0DE72ACE2 03 0000` (16, the
  chain captures) and `C0DE72ACE2 04 0001` (25, every Noir recording, which is
  every recording that publishes **source**). The published engine reads the
  first and rejects the second, so no demo session has a trace open at all, and
  the two journeys that can judge the origin capability are both on that side of
  the split. **Eleven journeys then reported, in the product's own vocabulary,
  that panes were empty and values never arrived.** All eleven were true, and
  none of them was about the product.

  Nothing on screen says so, which is why it took the wire to find: the page
  reaches `phase=ready` with twenty-four live controls and a State pane full of
  the exporter's rows, because the failing `configurationDone` arrives *second*,
  after a successful one. Every settle condition in this directory is satisfied
  by a session whose engine never opened its recording.

  `run.mjs` now has an **Arm II** that refuses to judge in that state, for the
  same reason Arm I refuses to judge when the browser cannot lay out text, and
  it exits 2 rather than 1 — a red journey is a claim about the product, and
  this is a refusal to make one.

  **THIS IS OPEN, AND RE-FETCHING IS NOT THE REMEDY.** Two engine builds were
  taken from the publisher four hours apart on the same day —
  `3009b9892fa181cf…` and `2250e91aec39d2a6…` — and **both refuse this corpus**,
  in the same place, with the same message. `just journeys-engine` will fetch a
  third and may well fetch a fourth that also refuses. Until an engine that
  reads `C0DE72ACE2 04 0001` is published, the way to get a verdict out of this
  suite is to stage one that does:

  ```
  node tools/journeys/run.mjs --engine-cache <dir-holding-a-working-engine>
  ```

  `cf79c4bf9854465b…` is such an engine and is what every measurement recorded
  above was taken on. The real fix belongs upstream, in whatever writes or reads
  those containers; nothing in this repository can pin its way out of it, and
  `fetch-engine.sh`'s header explains at length why it should not try.
* `O4` — the same journey's red, arriving as a **vacuity**. The detail reads
  `counted 0, the claim says 0`. The assertion is `countIs(naming.length,
  shownHere.originControls)`, and its own comment argues it cannot pass vacuously
  because an earlier verdict asserts `classified >= 1`. That argument assumes a red
  assertion *stops* the journey, and it does not: the earlier assertion fails, the
  run continues, `originControls` is 0, and `0 === 0` is green. **An implication is
  only as strong as its antecedent** — the rule this file already states — and here
  the antecedent is asserted and then not relied upon.

  **IT IS A CLASS, NOT A LINE, AND IT WAS COUNTED RATHER THAN GUESSED.** The
  broken-engine run above is the stress test the class needed, because it fails
  antecedents everywhere at once. Over that one report: **34 zero-against-zero
  verdicts stood GREEN after their own journey had already recorded a failure,
  across 8 of the 23 journeys** — journey 07's title check is one of 34. Going
  only to the line the arm named would have left 33.

  `harness.mjs` now refuses them, in `countIs` and in `atLeast` both. The rule
  is the one the shape gives away: a zero-against-zero verdict recorded in a
  journey that has *already failed* measures nothing, because the failure
  upstream is what emptied the set. It is recorded as `[VACUOUS]` — still
  counted, still named, never green.

  **Three remedies were on the table and two were rejected, which is worth
  writing down.** *Halt the journey at its first failure* is the obvious one and
  is actively harmful: it shortens the run, so `declared === j.total` reddens
  every failing journey a second time for a spurious reason, and `selftest.mjs`
  resolves an arm's target **by name in the recorded report** — so every arm
  aimed past the first failure would score NEVER RAN. That is `O1`'s disease
  generalised to the whole suite. *Assert a non-zero floor at each site* is
  correct and does not scale: it is ~150 `countIs` call sites edited by hand, and
  the sites that need it are exactly the ones nobody can spot by reading. The
  latch is the third option — re-establish the antecedent — made structural, and
  it needs no call-site changes at all.

  **And it is tagged `vacuous`, not merely failed, because the mirror-image
  error is manufacturing kills.** A mutation that reddens some earlier assertion
  would otherwise redden every zero-against-zero verdict after it and score a
  kill the arm did not earn — a false `KILLED`, which this directory already
  calls the worse of the two. `selftest.mjs` reads the flag and scores such a
  flip **NEVER RAN**: you cannot certify that an assertion bites using a run in
  which something else was already broken. A real flip is untouched —
  `countIs(0, 2)` after a red is still judged on its numbers, and still kills.
* `H`, `Z2` — genuine survivals, reproduced in two independent runs.

One arm is **flaky** and only two complete runs could show it: `FL2/the-panes-move-
before-the-values-arrive` SURVIVED in one run and was KILLED in the other.

**IT IS NOT A COIN. IT IS THE MACHINE, AND IT IS REPRODUCIBLE ON EACH SIDE.**
Measured on one tree with the defect in place:

| environment | blinks per run | verdict |
|---|---|---|
| load average 128 | 3, 4, 4, 4, 5, 5, 6, 6 | **KILLED 8 of 8** |
| load average 7–19 (idle) | 0, 1, 0, 0, 0 | **SURVIVED 4 of 5** |

The blink is the gap between "the position is known" and "the values have
arrived" — about 13 ms against a 16.7 ms frame. On a loaded machine the engine
lags, the gap widens past a frame, and the contradiction is composited. On an
idle one the reply is back before the next frame and nothing is painted. **The
faster the machine, the less observable the defect** — which is equally true of
the defect itself, and is why a visitor could report the flicker and a developer
on a fast laptop could not reproduce it.

The load was not the suite's. **96 orphaned busy-loop processes**, leaked by two
unrelated agents' load experiments (a `for p in $PIDS; do kill "$p"; done` that
never fired, because zsh does not word-split unquoted expansions), held this
machine at load 128–175 for hours. The original pass that produced FL2's split
verdict ran inside that. Two runs, two environments, one tree — and neither
transcript recorded which. It is the same lesson `lib/engine.mjs` already
carries about the unpinned engine, arriving through the scheduler instead.

Sampling harder does not fix it: the idle runs sampled 84–172 frames per
position, far above the density floor added here. **What was tried and does not
work** — holding `ct/load-locals` replies back by 220 ms so the window outlasts a
frame — makes the mutated tree blink at all six positions 3 of 3, *and the
unmutated tree blink at all six positions 3 of 3*. An instrument that reddens a
correct tree is not an instrument, so it was reverted rather than shipped. That
result deserves its own look: the guard is meant to hold the paint until values
land, `LocalsDeadlineMs` is 8000 ms so no timeout is involved, and a 220 ms
engine still produces the contradictory frame. Either the guard misses a paint
path or it is a race the product usually wins rather than a guarantee. **Not
claimed as a defect here** — it is one measurement.

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

The demo chain has been rebuilt into a suite of purpose-built Noir programs, one
per capability, and its manifest has landed. `tourManifest()` / `programsWith()`
are the seam: a journey reads `fixtures/trace/tour/manifest.json` and selects on
a program's declared `capabilities[]` — journey 08 selects the `failure` program
that way. The capability vocabulary is the manifest's own `capabilities` list;
read it there rather than from a copy. A capability no program declares yields
an empty set, so a journey written against it finds no subjects and **fails its
non-vacuity guard** rather than passing over nothing.

Two asymmetries to assert rather than paper over when parity journeys arrive: a
chain trace is rung 3 (no source, no names) while a demo trace is source-level —
journeys 01 and 05 already split on exactly that, and the split is the finding.
The second used to read "BlockTracer has no origin-chain surface at all, so a
cross-consumer parity claim cannot be 'the three agree everywhere'". **That
argument no longer holds** — the surface ships (`session_project.nim` builds the
`OriginChainVM`, `debugger.nim` renders the `.storigin` control,
`live_origin.nim` reads the reply back) — and no cross-consumer origin claim has
been written to replace it. What remains asymmetric is fidelity, not existence.
Where they cannot agree, the difference is the assertion.

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
