# BlockTracer visual-design capture harness (VD.0)

Automated, targetable, reproducible screenshot capture across every page,
state, theme and viewport — the mechanical foundation of every review round in
the [BlockTracer Visual Design campaign][milestones].

It implements tier 1 of the four-tier hierarchy in [visual-design-iteration.md][method]
and produces the images tiers 2–4 consume.

[milestones]: ../../../codetracer-specs/BlockTracer/BlockTracer-Visual-Design.milestones.org
[method]: ../../../codetracer-specs/Methodologies/visual-design-iteration.md

## Setup

```
just capture-setup          # npm install + playwright install chromium
```

Requires Node 20+. The site is built by the Nim exporter, which the harness
runs for you unless you pass `--no-build`.

## Capturing

```
just capture                                     # FULL REGENERATION
just capture "--view tx-detail"                  # one view, every size and theme
just capture "--view home --size wide"           # one view at one viewport
just capture "--size mobile"                     # every view at one viewport
just capture "--theme dark"                      # one theme
just capture "--view home --no-build"            # skip the exporter
just capture-list                                # the view list, capture nothing
```

Images land in `screenshots/` as `<view>__<size>__<theme>.png`, alongside a
`manifest.json` recording what produced them.

**Full regeneration cleans `screenshots/` first**, so a renamed or deleted view
leaves no stale image behind. A *targeted* run never cleans — it overwrites
only what it targets, because an agent iterating on one view must not destroy
the rest of the set. `--prune` deletes orphans without a full recapture.

## The named view list

`views.mjs` is the single source of truth for what gets captured:

| Axis | Values |
| --- | --- |
| Viewports | `wide` 1920×1080 · `laptop` 1440×900 · `tablet` 1024×768 · `mobile` 375×812 |
| Themes | `light`, `dark` — captured independently, never by inheritance |

Routes are resolved **semantically**, not by hard-coded hash: `nthTx(0)` and
`headBlock` in `lib/entities.mjs` read the built data plane, so a change to the
demo seed does not silently rename every image and re-point every baseline.

### `status: ready` and `status: pending`

The list is complete with respect to
[Page-Descriptions.md](../../../codetracer-specs/BlockTracer/Page-Descriptions.md) —
every route in its §1 map and every row of its §14 degraded-state catalogue.
The client currently renders five route types, so most views are `pending` with
a stated `pendingReason`. They are listed, counted and reported as unmet
captures, never silently dropped and never photographed against a 404 that a
reviewer would mistake for a styled page. When a route lands, flipping
`status` is the whole change.

`spec-inventory.mjs` is the machine-readable transcription of that spec, and
`check-coverage.mjs` fails if any entry has no named view.

## Determinism

Everything that makes a capture reproducible lives in `lib/determinism.mjs`,
and each control names what it defends against.

| Requirement | How |
| --- | --- |
| Fixed fixture data | The demo generator is a pure function of a fixed seed and `dist/` rebuilds byte-identically; the manifest records a digest of the served tree |
| Frozen clock | `context.clock.install()` at `2026-01-15T12:00:00Z` before the first navigation, then advanced by a fixed 2000 ms budget after load |
| Disabled animation | `reducedMotion: 'reduce'`, an injected zero-duration stylesheet, `screenshot({animations:'disabled', caret:'hide'})` |
| Stable fonts | Brand faces served from the site's own origin; `document.fonts.ready` awaited before and after the settle budget; fontconfig pinned in the container |
| Fixed rasterisation | `--force-device-scale-factor=1`, `--force-color-profile=srgb`, `--font-render-hinting=none`, `--disable-lcd-text`, `--disable-gpu`, `--hide-scrollbars`, and the rest of `CHROMIUM_ARGS` |
| Fixed environment | `timezoneId: 'UTC'`, `locale: 'en-US'`, seeded `Math.random`, `--js-flags=--random-seed=…` |
| Debugger position | Every debugger view pins `?t=` from `DEBUG_TIME_COORDINATE`; an unpinned debugger capture is non-deterministic by construction |

## The pinned container

```
just capture-canary-pinned                       # tier-1 determinism check
just capture-pinned                              # full regeneration in the container
tools/capture/run-in-container.sh shell          # poke around inside
```

`Dockerfile` pins the Playwright base image **by digest**, installs a
fontconfig that removes glyph-rendering variance, and pins the npm package to
the version whose browsers the image carries. `run-in-container.sh` refuses to
run on a version skew, records the resolved image id and architecture in the
manifest, and runs with `--network=none` so nothing unpinned can be fetched.

**Architecture is part of the pin.** amd64 and arm64 Chromium do not rasterise
text identically. A hash is comparable only with another hash from the same
architecture; the manifest records which, so a cross-architecture comparison
shows up as one instead of as a regression.

The site is built on the **host** before the container starts. The image
carries no Nim toolchain on purpose: `dist/` is already byte-reproducible from
a fixed seed, so building it inside would add a variable without removing one.

## The determinism canary (tier 1)

```
just capture-canary                              # ADVISORY on a host
just capture-canary-pinned                       # the real tier-1 verdict
```

A handful of `{view, size, theme}` triples covering the distinct rendering
paths — dense text, a data table, a chart, one dark-theme view, one narrow
reflow — and **not** the full corpus. Exact comparison over hundreds of images
eventually flakes somewhere, and the response to a flaky mandatory gate is
always to switch it off.

Its job is not to detect regressions. It answers one question: *is the capture
harness still deterministic?* If it is not, every tier-2 baseline is quietly
worthless.

The verdict goes to `screenshots/canary/status.json`. A run outside the pinned
container is marked `advisory` and is **not** accepted as a tier-1 pass — it
measured the runner, not the product.

## The gate that protects the baselines

```
just capture-gate
```

`require-deterministic.mjs` is what a baseline-comparing check must pass
through first. It refuses in four distinct ways — no verdict, stale verdict,
advisory verdict, failed canary — and in all four the correct downstream
behaviour is to report the perceptual comparison as **unreliable**, not to run
it and believe it. Collapsing those four into one would produce exactly the
failure it exists to prevent.

Do not raise a threshold to make this green. A threshold raised twice is a
defect in the capture, not in the threshold.

## Verifications

```
just capture-selftest                            # all four, end to end
tools/capture/run-in-container.sh selftest       # the same, pinned
```

| VD.0 verification | Implemented by |
| --- | --- |
| `verify_capture_covers_named_view_list` | `check-coverage.mjs` (A + C) |
| `verify_canary_capture_is_byte_identical` | `check-canary.mjs` |
| `verify_canary_failure_invalidates_the_baselines` | `require-deterministic.mjs`, exercised by `selftest.mjs` |
| `verify_full_regen_removes_stale_images` | `check-coverage.mjs` (D) + `selftest.mjs` |

## The review loop and the quality gate (VD.1)

Never view screenshots in the main context. Capture, then hand the paths to
disposable review sub-agents together with the brief, and read only their text
summaries.

[`tools/visual-review-brief.md`](../visual-review-brief.md) is what every
reviewer reads: product context, the reference direction, an expected-elements
block for **every one of the 62 named views**, two rubrics (explorer register
and debugger register), five reviewer lenses, the adversarial reviewer role,
the P1/P2/P3 severity definitions, and the gate.

```
1. change the UI
2. just capture "--view tx-detail --size wide --theme light"
3. just review-prompt "--view tx-detail --size wide --theme light --all"
     → six prompts: L1..L5 and ADV. Launch them in parallel; a round of six
       costs the same wall-clock time as one.
4. record each reviewer's ```json block in reviews/ledger.json
5. just review-gate "--view tx-detail"
6. fix, re-capture, repeat
```

### The gate

`gate.mjs` decides the five **structural** conditions over the findings ledger:

| | Condition |
| --- | --- |
| G1 | every gated view has an expectation block, and every reviewer reports `expectedElements: "present"` |
| G2 | all five lenses **and** the adversarial reviewer reviewed the exact image |
| G3 | zero unresolved P1 and P2 — a P1 can only be `fixed`; a P2 may be `waived` with a reason *and* a human sign-off |
| G4 | a reference-parity check is **recorded** with a verdict and a named human — never computed |
| G5 | a human sign-off names a person, a date and the ledger revision, and that revision is current |

The rating appears in none of them. `just review-gate-explain` prints the
ledger schema; `just review-gate-selftest` proves each condition independently
turns a passing ledger into a failing one, and that a missing or unparseable
ledger fails closed rather than going green for lack of anything to check.

**G6 — the tier-1 determinism precondition — is not enforced**, because VD.0's
pinned container has never been built. `gate.mjs` says so on every run rather
than leaving it to be discovered. G1–G5 are properties of the ledger and do not
depend on it.

### The per-view expectation blocks

`expectations.mjs` is the source; `render-brief.mjs` writes §4 of the brief from
it; `check-brief.mjs` enforces that every named view has a block, that no block
names a view that does not exist, that no block is a stub, and that the brief is
not stale with respect to its source.

### The deliberate break

`break-check.mjs` removes a required element from the product's source,
rebuilds, captures into `screenshots/break/<name>/`, **restores the source in a
`finally`**, and prints the review prompts — unchanged, so the reviewers are
never told anything was removed. The recorded outcome lives in
`reviews/break-round-*.json` and is re-gradeable with `--grade`.

```
just review-break                                       # list the breaks
just review-break "--break debug-affordance"            # run one
just review-break "--grade reviews/break-round-debug-affordance.json"
just review-selftest                                    # all three VD.1 verifications
```

| VD.1 verification | Implemented by |
| --- | --- |
| `verify_brief_has_expectation_block_per_view` | `check-brief.mjs` (+ a negative control in `review-selftest.mjs`) |
| `verify_deliberate_break_is_detected` | `break-check.mjs`, graded over the recorded round |
| `verify_gate_definition_is_machine_checkable` | `gate.mjs`, proved by `gate-selftest.mjs` |

## The foundations scope (VD.2)

`gate.mjs --foundations` answers a narrower question than the full gate:
*does this page pass on the FOUNDATIONS criteria alone, before page-specific
work begins?* The narrowing is written down rather than argued each time, and
it is enumerated EXHAUSTIVELY over both rubrics — every criterion A1–A10 and
B1–B10 is named as either in scope or excluded, with a reason, so a criterion
cannot escape by being forgotten. `gate-selftest.mjs` asserts the enumeration
is exhaustive and disjoint.

| | |
| --- | --- |
| **In scope** | A1, A2, A4, A5, A7, A10, B1, B2, B7 — the type scale, the spacing rhythm, colour roles, numeric/monospace treatment, focus/hover/active, and register density |
| **Excluded** | A3, A6, A8, A9, B3–B6, B8–B10, and every finding with **no** criterion (a missing element is content) |
| **Relaxed** | G1 → G1f: the §4 presence check must have been PERFORMED by every reviewer, not that it passed |
| **Narrowed** | G3 → G3f: only findings carrying a foundations criterion |
| **Unchanged** | G2 (six lenses), G4 (reference parity), G5 (human sign-off) |

The full gate is always computed and printed alongside, never replaced by, the
foundations verdict — so "foundations passed" cannot be read as "this page is
done".

```
just review-gate-foundations                # the narrowed gate + the full one
just review-gate-foundations "--json"       # both verdicts, machine-readable
```

## The token lint (VD.2)

`verify_no_raw_values_in_views` lives in `tools/design/`, not here, because it
is a property of the SOURCE rather than of a capture.

```
just design-check        # the lint, including the shipped-CSS cross-check
just design-check-bare   # what CI runs: no build needed
just design-selftest     # proof that it decides
just design-explain      # what each check decides, and why
```

| VD.2 verification | Implemented by |
| --- | --- |
| `verify_no_raw_values_in_views` | `tools/design/check-tokens.mjs`, proved by `check-tokens-selftest.mjs` |
| `verify_foundations_round_reaches_bar` | `gate.mjs --foundations` over `reviews/ledger.json` |

## Files

| File | Role |
| --- | --- |
| `views.mjs` | Named views, viewports, themes, canary — the source of truth |
| `spec-inventory.mjs` | Page-Descriptions transcribed for machine checking |
| `capture.mjs` | The capture CLI |
| `check-coverage.mjs` | Coverage and stale-image verification |
| `check-canary.mjs` | Tier-1 byte-identity check |
| `require-deterministic.mjs` | The gate baselines must pass through |
| `selftest.mjs` | All four VD.0 verifications |
| `lib/determinism.mjs` | Flags, clock, motion, fonts, theme injection |
| `lib/entities.mjs` | Semantic route resolution over the built data plane |
| `lib/server.mjs` | Clean-URL static server for `dist/` |
| `Dockerfile`, `fonts-local.conf`, `run-in-container.sh` | The pinned container |
