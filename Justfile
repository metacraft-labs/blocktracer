# BlockTracer workspace commands.
# `just` recipes wrap the nimble tasks so the workspace has one entry point.

# Run the conformance + publisher + Client SDK test suites, and the SDK's
# bidirectional import lint.
test:
    nim c -r --hints:off tests/tcontract.nim
    nim c -r --hints:off tests/tpublish.nim
    nim c -r --hints:off tests/tclientsdk.nim
    ci/test/client-sdk-boundary.sh
    ci/test/client-sdk-boundary-test.sh

# ── the chain capture tooling's own selftests ──────────────────────────────
#
# FOUR suites — 87 + 19 + 18 + 22 = 146 counted assertions — over the four
# decisions the capture path makes that nothing else can check afterwards:
# which outcome a driver run is (`replay-selftest`), whether a snapshot may be
# called frozen (`freeze-snapshot-selftest`), when a supervised watch is
# allowed to stop (`watch-chain-selftest`), and which call frames a container's
# event stream folds (`calltrace-fold-selftest`).
#
# The count said "three suites, 124" while the recipe ran four: the fold suite
# was wired in with the folded Call Trace and the sentence above it was not
# moved. It is restated here as a reading of what the recipe runs, which is the
# only version of it that can be checked.
#
# THEY WERE REFERENCED BY NOTHING. Not by `just test`, not by any CI job, not
# by `ci-coverage.sh` — whose enumeration covers `ci/test/*.sh` and
# `client/Justfile`'s aggregate and reaches nothing under `tools/`. That is the
# same hole `deploy-gates` was created for after `check-assets-selftest.mjs`
# was found dead, and these three were in it: the only evidence they could go
# red was that someone had once watched them.
#
# All four are OFFLINE and toolchain-free — plain node plus bash, a mock node
# for the freeze gate, recorded driver output for the replay rule, and for the
# fold suite an event stream reconstructed from the committed sidecars rather
# than read out of a `.ct` with `ct-print` — so they run
# on a stock runner and are wired into CI's `deploy-gates` job for exactly the
# reason its header gives: a gate that needs the busy Nix runner to prove it
# can fail is a gate that gets skipped.
chain-selftest:
    node tools/chain/replay-selftest.mjs
    node tools/chain/freeze-snapshot-selftest.mjs
    bash tools/chain/watch-chain-selftest.sh
    node tools/chain/calltrace-fold-selftest.mjs

# ── what a frozen capture would have measured ──────────────────────────────
#
# Every transaction in `client/fixtures/chain/` reads `declaredRung: 3` and
# carries NO `artifacts` key, because its runtime predates off-chain artifact
# resolution. That is an absence of measurement and not a measured ceiling, and
# the difference cannot be settled by re-capturing: all eight bodies are pruned
# (CHAIN-CAPTURE.md §1), permanently.
#
# So it is settled without the transaction — from the container's interned
# addresses plus the instance and class the node still serves — by the resolver
# the driver itself uses. READ-ONLY over the freeze. See CHAIN-CAPTURE.md §6.1,
# including the paragraph on what a `resolved: true` here does NOT mean.
#
# Needs a runtime checkout carrying `replay/src/artifact_resolution.ts`, and
# reaches the chain, npm and a block explorer — so it is by hand and in no
# build, the same standing as `chain-instructions`.
#
#     just chain-frozen-artifacts ../aztec-avm-runtime
chain-frozen-artifacts runtime:
    node --experimental-strip-types tools/chain/resolve-frozen-artifacts.mjs \
      --runtime {{runtime}}

# ── the chain captures' instruction streams ────────────────────────────────
#
# Derive `instructions/<tx>.json` beside a committed capture's containers: the
# per-step program counter, opcode number and gas reading the recording carries.
# `ingest.nim` publishes whatever is there and the Code pane renders it as an
# instruction listing, which is the honest floor for a recording no source
# resolved for.
#
# DELIBERATELY NOT PART OF ANY BUILD, and not part of `just test`. Reading a
# `.ct` needs `ct-print` from a `codetracer-trace-format-nim` checkout, and this
# repository does not depend on that one: nothing here imports it, `flake.nix`
# does not name it, and adding it would put a Nim library on the site build's
# source-dependency graph for the sake of an offline derivation. Same standing
# as `fixtures/trace/tour/record.sh` and
# `client/fixtures/demo-session/extract-flow.mjs`: run by hand, output
# committed, and a snapshot with none is a valid tree that renders the state it
# always did.
#
# THIS COMMENT USED TO SAY THE DEPENDENCY "CANNOT BE ONE — the site build is
# hermetic", and that overstatement is worth correcting where it stood, because
# it was cited. `CHAIN-CAPTURE.md` §6.6 rested the empty Call Trace pane on it
# and concluded the frames could only ever be listed by a live session.
#
# `nix build` REALLY IS HERMETIC — sandboxed, no network — and that is not what
# was wrong. What was wrong was reasoning from it to what the SITE MAY CONTAIN.
# This derivation does not run in the build at all: it runs here, by hand, and
# commits a JSON file that is then an ordinary source input, exactly like the
# vendored `.ct` containers beside it. Hermeticity constrains what the build may
# REACH FOR; it says nothing about what a committed input may hold.
#
# The deploy makes the same distinction and states it: the workflow adds the
# replay engine to the staged site by `curl` AFTER `nix build`, precisely
# because the build cannot reach the network
# (`.github/workflows/deploy-cloudflare-pages.yml`, `fetch-engine.sh`). So the
# line between "the build is sealed" and "the product may only contain what the
# build could compute" was already drawn correctly elsewhere in this repository,
# and only §6.6 crossed it.
#
# The rule that IS real here is source-dependency hygiene, stated in the
# paragraph above. `chain-calltrace` below is the same argument taken to its
# conclusion.
#
#     CT_PRINT=../codetracer-trace-format-nim/ct-print just chain-instructions
chain-instructions:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in client/fixtures/chain/*/; do
      [ -f "$d/snapshot.json" ] || continue
      node tools/chain/derive-instructions.mjs "$d"
    done

# ── the chain captures' call frames ─────────────────────────────────────────
#
# Derive `calltrace/<tx>.json` beside a committed capture's containers: the
# frames the recording opened, their nesting, the step each began at and the
# arguments the recorder wrote on the call.
#
# WHY IT EXISTS. The Call Trace pane served a paragraph on every real chain
# transaction — "they are listed once the session is live" — while the manifest
# beside it published `execution.frames: 1`. The frames were in the containers
# the whole time; what was missing was a derivation, not a capability. See
# `chain-instructions` above for the correction to the reasoning that had this
# recorded as impossible.
#
# SAME STANDING AS `chain-instructions`, in every respect: not part of any build
# and not part of `just test`, needs `ct-print` from a
# `codetracer-trace-format-nim` checkout, run by hand, output committed. A
# snapshot with no `calltrace/` is a VALID tree — `ingest.nim` publishes
# whatever is there and the pane falls back to the note it always showed.
#
#     CT_PRINT=../codetracer-trace-format-nim/ct-print just chain-calltrace
chain-calltrace:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in client/fixtures/chain/*/; do
      [ -f "$d/snapshot.json" ] || continue
      node tools/chain/derive-calltrace.mjs "$d"
    done

# ── the Noir-frame fixture, and its two derivations ─────────────────────────
#
# `client/fixtures/noir-frames/` is the container the NEW recorder would have
# written for the transaction this repository publishes. It exists because that
# transaction cannot be re-recorded — the node serves bodies out of its active
# pool for about an hour and that hour is long past — and because the view side
# needed a Noir call tree to be built against before one could be published.
#
# Its frame tree is `aztec-avm-runtime`'s own `ContractSourceMap` and
# `NoirFrameTracker`, imported and RUN; its bytes are the real `CtWriter` driving
# the real `aztec_ct_writer.wasm`. Its per-step AVM registers are ZERO and say so
# in `provenance.json`. Read `tools/chain/record-noir-frames-fixture.mjs`'s header
# before trusting any number out of it — the split between what is measured, what
# is reconstructed and what is zero is the whole honesty of the fixture.
#
# NEEDS AN aztec-avm-runtime CHECKOUT at 26cac14 or later with the wasm built
# (`just ct-writer-build` there), a version-matched FeeJuice artifact, and node
# >= 22 for the TypeScript imports. Same standing as `chain-calltrace`: not part
# of any build, not part of `just test`, run by hand, output committed.
#
# BOTH DERIVATIONS ARE COMMITTED and both are asserted. `calltrace/` is the
# default view and `calltrace-unfolded/` is the same container with the policy
# turned off — a default that cannot be turned off is not a default, and the two
# carrying the same forty-six frames is what makes "folded, not elided" a
# measurement rather than a claim.
#
#     just noir-frames-fixture ../aztec-avm-runtime <path>/FeeJuice.json
noir-frames-fixture avm artifact:
    #!/usr/bin/env bash
    set -euo pipefail
    out=client/fixtures/noir-frames
    node tools/chain/record-noir-frames-fixture.mjs \
      --avm-runtime "{{avm}}" --artifact "{{artifact}}" --out "$out"
    node tools/chain/derive-calltrace.mjs "$out"
    rm -rf "$out/calltrace-unfolded"
    tmp="$(mktemp -d)"
    cp "$out/snapshot.json" "$tmp/"; cp -r "$out/ct" "$tmp/"
    node tools/chain/derive-calltrace.mjs --no-fold "$tmp"
    mv "$tmp/calltrace" "$out/calltrace-unfolded"
    rm -rf "$tmp"
    node tools/chain/calltrace-fold-selftest.mjs

# ── @blocktracer/client — the Client SDK (M12a) ─────────────────────────────
# The chain-aware layer above the CodeTracer Embed SDK. See
# codetracer-specs/BlockTracer/Client-SDK.md.

# The consumer-side conformance suite. Deliberately needs NO debugger on the
# Nim path: that the chain half compiles without one is the layering.
sdk-test:
    nim c -r --hints:off tests/tclientsdk.nim

# The bidirectional import lint (Client-SDK.md §1.1), plus its own self-test —
# every rule driven against a synthetic tree carrying a deliberate violation.
# Pass CODETRACER_SRC (or keep a ../codetracer checkout) to scan the REAL Embed
# SDK for chain concepts as well.
sdk-boundary:
    ci/test/client-sdk-boundary.sh
    ci/test/client-sdk-boundary-test.sh

# The handoff: compile and run tests/tembedhandoff.nim against the real Embed
# SDK, so "a TraceSource the Embed SDK accepts" is checked by the Embed SDK.
# Needs CODETRACER_SRC or a ../codetracer checkout (ci/embed-sdk-pin.env).
sdk-test-embed:
    ci/test/embed-handoff-test.sh --require

# ── BlockTracer's own ViewModel layer (M12) ─────────────────────────────────
# Front-End-Architecture.md §3's table. The Tier-1 half runs with no debugger
# on the Nim path (`cd client && just test-viewmodels`); this is the other
# half — the degraded-state seam, compiled against the real Embed SDK, so the
# wire spellings the panes parse cannot drift from the ones this layer emits.
viewmodel-seam:
    ci/test/viewmodel-seam-test.sh --require

# ── The debug route (M8a/M8b) ──────────────────────────────────────────────
# The hermetic half — the route, the arrangement, the pane renderers, the
# source renderer, §7.0's landing rule — is `cd client && just test-debug-route`
# and needs no debugger on the Nim path. These two are the halves that do.

# The five panes rendered over the Embed SDK's OWN five ViewModels, driven
# through MockBackendService. Needs CODETRACER_SRC or a ../codetracer checkout.
debug-panes:
    ci/test/debug-panes-test.sh --require

# The VENDORED copies of CodeTracer modules: their bytes still hash to their
# manifests, and they still agree with upstream on every observable. Each
# self-test drives every failure path, so neither check is one nobody has seen
# say no.
#
# Two of them, and they are vendored for the same reason and pinned to
# different things:
#
#   * `headless_app/layout_model.nim` — the pane arrangement. NOT in the Embed
#     SDK's tree, so it tracks its own module's mainline.
#   * `viewmodel/viewmodels/flow_layout.nim` + `ui/flow_loop_math.nim` — the
#     Omniscience layout arithmetic. INSIDE the tree `ci/embed-sdk-pin.env`
#     names, so its manifest commit must equal that pin and the check says so:
#     the static export and the hydration bundle place inline values with this
#     one arithmetic, and two commits would be two versions of it laying out
#     one page.
layout-vendor:
    ci/test/layout-model-vendor.sh --require
    ci/test/layout-model-vendor-test.sh
    ci/test/flow-layout-vendor.sh --require
    ci/test/flow-layout-vendor-test.sh

# ── The Noir corpus (fixtures/trace/tour) ───────────────────────────────────
# Two sets: `programs` are recordable and are the capability tour the demo chain
# publishes; `toolchainPrograms` exercise the toolchain and cannot produce a
# servable recording. See fixtures/trace/tour/README.md.

# Both sets, checked against what the toolchain actually does — including the
# KNOWN FAILURES, which report loudly when they start passing rather than
# asserting that a broken thing stays broken.
corpus-check args="":
    fixtures/trace/tour/check-corpus.sh {{args}}

# Proof that the known-failure mechanism decides in BOTH directions: an entry
# that stops holding must FAIL the run, the same observation without the flag
# must PASS, and the real corpus must pass so neither arm is vacuous.
corpus-selftest:
    fixtures/trace/tour/check-corpus.sh --selftest

# Re-record every container. DELIBERATELY, not on every build: `nargo trace` is
# not byte-deterministic. Pass an id to re-record one.
corpus-record args="":
    fixtures/trace/tour/record.sh {{args}}

# The tour's coverage of the Noir LANGUAGE, enumerated from the compiler's own
# AST enums rather than from a sample of programs. Every form is either
# demonstrated or carries an explicit reason; a form with neither fails.
corpus-coverage:
    node tools/noir-coverage.mjs

# Regenerate docs/NOIR-COVERAGE.md from the same source of truth.
corpus-coverage-doc:
    node tools/noir-coverage.mjs --markdown

# ── The engine seam (the Noir DAP port) ────────────────────────────────────
# CodeTracer's Noir DAP tests — `noir_flow_dap_test.rs`, `origin_noir_dap_test.rs`
# and the `noir-space-ship` GUI journey — over the engine BlockTracer actually
# ships and the container it actually vendors.
#
# This is the ONE lane in the repository that drives a real replay session: the
# Embed SDK's own `WorkerBackendService` against the published wasm32 engine in
# a Node worker, over `fixtures/trace/noir_space_ship/zk_shields.ct`. Every
# check names an artefact — a stepped position, a frame count, a variable's
# value, a loop iteration — and never a `success: true`.
#
# It needs the Embed SDK ($CODETRACER_SRC or ../codetracer) and an engine
# ($REPLAY_ENGINE_DIR, else client/dist/replay-engine, else it fetches the
# published one). It FAILS rather than skips when either is missing.
#
# **rc 124 means a request the engine never answered.** Not a slow test, not a
# broken one: a dropped request, which is what a pane spinning forever looks
# like from this side.
noir-engine-dap:
    ci/test/noir-engine-dap.sh

# The self-test: every rule above driven against a deliberately broken input,
# each arm asserting that the check written FOR it is the one that reddens —
# plus the control that matters for a suite whose deliverable is failures, that
# each red check goes green on the engine's own reported values and so is not
# stuck red.
noir-engine-dap-test:
    ci/test/noir-engine-dap-test.sh

# Generate a demo static tree into ./demo-site.
demo-gen out="demo-site" seed="blocktracer-demo-0":
    nim c -r --hints:off src/blocktracer_demo_gen.nim --out:{{out}} --seed:{{seed}}

# Validate a static tree against the contract.
validate dir="demo-site":
    nim c -r --hints:off src/blocktracer_validate.nim {{dir}}

# Generate a demo tree and validate it (the M5c end-to-end check).
demo: (demo-gen) (validate)

# Publish a generated tree into a local object-store directory (M8 delta publisher).
# Idempotent + resumable: re-run to upload only new objects and flip current.json.
publish tree="demo-site" dest="published":
    nim c -r --hints:off src/blocktracer_publish.nim --tree {{tree}} --backend local --dest {{dest}}

# ── Visual-design capture harness (VD.0) ────────────────────────────────────
# Screenshots of every named view at every viewport in both themes. See
# tools/capture/README.md. `capture` with no arguments is a FULL REGENERATION
# and cleans screenshots/ first, so a renamed view leaves no stale image.

# Install the pinned Playwright package and its browser (once).
#
# `npm ci` and not `npm install`: the lockfile pins the exact version, and that
# version must equal the one the pinned Nix environment's browser bundle was
# built for (`nix run .#capture-env -- --print-pin | grep playwright`). A skewed
# pair usually WORKS and silently changes the pixels, which is why
# lib/pinned-env.mjs refuses it rather than hashing it.
#
# The browser download is for HOST runs only. Inside the pinned environment the
# browsers come from the store, so the download is skipped there.
capture-setup:
    cd tools/capture && npm ci --no-audit --no-fund && npx playwright install chromium

# Capture. Pass targeting flags through, e.g.
#   just capture "--view tx-detail --size wide --theme dark"
capture args="":
    node tools/capture/capture.mjs {{args}}

# Print the named view list, the viewport set, the theme axis and the canary.
capture-list:
    node tools/capture/capture.mjs --list

# verify_capture_covers_named_view_list, verify_full_regen_removes_stale_images
# and verify_corpus_subject_drift_is_detected — the last one being the check that
# every PNG is a photograph of the subject its view still resolves to. The first
# three assertions are about names; that one is about content, and it is the only
# thing that notices a chain rename moving every image's subject while the view
# list, the file list and the chain coverage all stay green.
capture-coverage:
    node tools/capture/check-coverage.mjs

# verify_canary_capture_is_byte_identical — ADVISORY on a host; use
# `just capture-canary-pinned` for a tier-1 verdict.
capture-canary:
    node tools/capture/check-canary.mjs

# What the pinned capture environment fixes, and its content-hash id. Two
# hashes are comparable only if two runs print the same id.
capture-env-pin:
    nix run .#capture-env -- --print-pin

# The tier-1 determinism canary, in the pinned capture environment
# (tools/capture/capture-env.nix — browser build, fontconfig set and renderer
# flags fixed; no daemon, no VM).
#
# ON DARWIN THIS IS STILL ADVISORY. The pinned Chromium rasterises through the
# host's CoreGraphics/CoreText stack, which no derivation can pin, so the
# harness refuses to call it a tier-1 verdict however pinned the inputs are.
# Linux is where a tier-1 verdict is producible, and CI is the environment that
# has to reproduce itself.
capture-canary-pinned args="":
    nix run .#capture-env -- node tools/capture/check-canary.mjs --no-build {{args}}

# Full regeneration in the pinned capture environment.
capture-pinned args="":
    nix run .#capture-env -- node tools/capture/capture.mjs --no-build {{args}}

# All four VD.0 verifications in the pinned capture environment.
capture-selftest-pinned:
    nix run .#capture-env -- node tools/capture/selftest.mjs

# The gate a baseline comparison must pass before it may be believed.
capture-gate:
    node tools/capture/require-deterministic.mjs

# ── Journey conformance (spec claims, judged in a browser) ──────────────────
# Each journey is a sentence from the spec — "a visitor who opens X sees Y" —
# asserted by loading the artefact CI deploys in a real browser. See
# tools/journeys/README.md for what is and is not claimed.
#
# These are NOT `just test`: that recipe is the Nim suites over rendered markup,
# which run in seconds and need no browser. These need a built site, a browser
# and — for the journeys that drive a live session — the 18 MB replay engine.

# NOT into client/dist: the exporter removes that directory and writes it again,
# so an engine staged inside it is destroyed by the next export.

# Fetch the replay engine into client/.replay-engine-cache, once (18 MB).
journeys-engine:
    ./client/hydrate/fetch-engine.sh client/.replay-engine-cache

# Run the journeys over an already-built site (client/dist).
journeys *ARGS:
    node tools/journeys/run.mjs {{ARGS}}

# `export-hydrated`, not `export`: the two disagree about the debug route, and
# the deployed one is the one that ships the hydration bundle.

# Build the deployed shape, then run every journey over it.
journeys-build: journeys-engine
    cd client && just export-hydrated
    node tools/journeys/run.mjs

# Slower than `journeys-build` and the stronger claim: it removes every question
# about which flags the local build used. This is what CI runs.

# The journeys over `nix build .#default` — byte-for-byte what the deploy uploads.
journeys-deployed:
    #!/usr/bin/env bash
    set -euo pipefail
    nix build .#default
    rm -rf .journey-site && mkdir -p .journey-site
    cp -R result/. .journey-site/
    chmod -R u+w .journey-site
    # INTO THE CACHE, and let the runner stage from there — which is what the
    # `journeys` CI job already does, and what `lib/engine.mjs` is written for.
    # Fetching straight into `.journey-site/replay-engine` made this the only
    # path that could present `stageEngine` with two complete-but-different
    # engines (a fetched one in the tree, an older one in the cache), which it
    # now REFUSES rather than silently picking between. One fetch, one cache,
    # one engine, and `--engine-cache` stays the only way to name a different one.
    ./client/hydrate/fetch-engine.sh client/.replay-engine-cache
    node tools/journeys/run.mjs --dist .journey-site

# Each mutation is restored byte-for-byte, and the assertion is proved green
# again afterwards — otherwise a mutation that failed to apply scores a kill.

# Do the journeys bite? One mutation per arm, each aimed at one named assertion.
journeys-selftest:
    node tools/journeys/selftest.mjs

# One SHARD of it, for a runner with a wall-clock box. 62 arms is ~115 minutes
# and `the-timeline-can-be-dragged` alone is ~45 of them; a run under an agent's
# background task was killed at ~60 minutes on arm 47 of 62 with no verdict.
# `--arm` cannot answer that — it selects by name, and a name is not a budget.
#
#   just journeys-selftest-shard 1 4     # …and 2 4, 3 4, 4 4, in any order
#   just journeys-selftest-combine 4
#
# A SHARD IS NOT A RUN. Its verdict is about the arms it holds; `combine` is
# where the suite's claim is made, and it refuses unless the shards cover the
# arm list exactly.
journeys-selftest-shard I OF:
    node tools/journeys/selftest.mjs --shard {{I}}/{{OF}}

# ONE verdict over the shard journals. Fails unless every arm was run exactly
# once and killed; a shard that never ran is reported by name as DID NOT RUN,
# because "three of four shards passed" is not a claim about this suite.
journeys-selftest-combine OF:
    node tools/journeys/selftest.mjs --combine {{OF}}

# Does the selftest SAY when it did not run? It has been observed dying part-way
# through its arm list with no RESULT line, and a stall producing no verdict
# reads to a human exactly like a suite nobody bothered to run. Machinery that
# reports an ending is only exercised by an ending, so an ordinary run covers
# none of it: this produces four real ones — an unmatched filter, SIGTERM
# mid-arm, SIGKILL mid-arm, and a throw — and demands each name itself. It also
# proves the SIGTERM path puts the mutated file back, which a `finally` cannot.
journeys-selftest-verdict:
    bash tools/journeys/selftest-verdict-test.sh

# All four VD.0 verifications, end to end.
capture-selftest:
    node tools/capture/selftest.mjs

# ── Review brief and the quality gate (VD.1) ────────────────────────────────
# The brief's §4 is generated from tools/capture/expectations.mjs; the gate is
# evaluated over reviews/ledger.json. See tools/visual-review-brief.md.

# Regenerate the brief's per-view expected-elements section.
review-brief:
    node tools/capture/render-brief.mjs

# verify_brief_has_expectation_block_per_view
review-check-brief:
    node tools/capture/check-brief.mjs

# verify_corpus_names_the_build_it_photographs (H1) and
# verify_hydration_adds_no_class_the_page_cannot_draw (H2).
#
# The campaign photographs `client/dist` — `just export`, zero JavaScript — and
# the deployed site is `flake.nix`'s `packages.default`, which exports the same
# routes with `-d:hydrationBundle`. `debugLayout` emits that script, so every
# `debugger*` view and `tx-detail--session` are captures of a build no visitor
# is served. That is a gap in the INSTRUMENT, and until VD.11 nothing a reviewer
# read said which build was in front of them: one shipped reason string
# misattributed its own cause to it and one P1 was nearly filed on it.
#
# H1 decides the per-view answer from the two built trees and `render-brief.mjs`
# renders it into every block, so the brief's claim is measured. H2 is the
# assertion the campaign could not make before: a class the shipped bundle adds
# and the inlined stylesheet cannot draw is invisible to every capture and every
# reviewer, which is the affordance-that-lies defect with a build boundary
# hiding it.
#
# NO VERDICT rather than PASS without both trees — `just capture ""` builds them.
capture-hydration-divergence:
    node tools/capture/check-hydration-divergence.mjs

# Re-measure and rewrite the committed map. Read the diff: a view moving between
# arms means a route started or stopped serving a session.
capture-hydration-divergence-write:
    node tools/capture/check-hydration-divergence.mjs --write

# Emit the sub-agent prompts for one captured image, e.g.
#   just review-prompt "--view tx-detail --size wide --theme light --all"
review-prompt args="":
    node tools/capture/review-prompt.mjs {{args}}

# Merge reviewer reports into reviews/ledger.json. The ONLY way an entry gets
# into the ledger: a hand-written one is how VD.1's reviewer defeated the
# determinism gate, and the ledger is the gate's evidence. Each report is the
# ```json block brief §10 Part 2 defines.
#
#   just review-ingest "--dir reviews/rounds/vd5-round3 --gate-scope debugger/wide/dark"
#
# It also establishes the one thing gate.mjs cannot: that all six reviewers of
# a triple looked at the SAME bytes (G2's "the exact image"), by recording each
# capture's sha256 and refusing a set that disagrees.
review-ingest args="":
    node tools/capture/ingest-review.mjs {{args}}

# Does every ledger entry still match the report it was built from?
#
# `imageSha256` establishes that six reviewers looked at the same pixels;
# nothing established that the LEDGER still matches the round file it claims to
# have been built from — and that gap is not hypothetical. A reviewer agent that
# stalled and was relaunched finished 68 minutes later and rewrote its round
# file after the ingest had run, leaving a committed ledger entry and a file on
# disk that disagreed while every check in the pipeline stayed green: the gate
# re-hashes the IMAGE, and ingest had already finished.
#
# Reports NO VERDICT rather than PASS over a ledger with nothing to check.
#
# Pass a round directory to ALSO check the other direction — that every report
# FILE in it parses and reached the ledger:
#
#   just review-verify reviews/rounds/vd9-r1
#
# The two are different questions and the second one is not implied by the
# first. `--verify` walks the LEDGER, so a report that was never ingested leaves
# nothing to iterate over and the round looks complete from that side while a
# reviewer's judgement is missing from the evidence the gate decides over. In
# vd9-r1 a report was written with its json fence opened and never closed;
# ingest refused it, correctly and loudly, and had that refusal scrolled past,
# every remaining check would have been green over a five-lens "six-lens" triple.
# It is the file-existence-is-not-completion hazard once more, one step later.
review-verify round="":
    node tools/capture/ingest-review.mjs {{ if round == "" { "--verify" } else { "--verify-round " + round } }}

# Proof that the ingest refuses — one case per rule, plus a base case that must
# be ACCEPTED so the file cannot pass by rejecting everything.
review-ingest-selftest:
    node tools/capture/ingest-selftest.mjs

# verify_gate_definition_is_machine_checkable — the gate over the findings ledger.
review-gate args="":
    node tools/capture/gate.mjs {{args}}

# The ledger schema and the five gate conditions.
review-gate-explain:
    node tools/capture/gate.mjs --explain

# Proof that the gate decides: every condition independently blocks.
review-gate-selftest:
    node tools/capture/gate-selftest.mjs

# verify_deliberate_break_is_detected — list, run, or grade a recorded round.
review-break args="--list":
    node tools/capture/break-check.mjs {{args}}

# All three VD.1 verifications, end to end.
review-selftest:
    node tools/capture/review-selftest.mjs

# ── Foundations pass (VD.2) ─────────────────────────────────────────────────
# The web-lineage token layer lives in client/src/design_system/web.tokens.json
# and is emitted by tokens.nim. See docs/DESIGN-DIVERGENCES-WEB.md.

# verify_no_raw_values_in_views, plus the Design-System.md §4.1 divergence rule.
# --require-built turns the shipped-CSS cross-check from NOT RUN into a failure,
# so the local run is strictly stronger than CI's bare-Node one.
design-check:
    node tools/design/check-tokens.mjs --require-built

# The same checks without a build — exactly what the visual-design CI job runs.
design-check-bare:
    node tools/design/check-tokens.mjs

# What each check decides, and why the allowlist is what it is.
design-explain:
    node tools/design/check-tokens.mjs --explain

# Regenerate the implemented-binding table in the divergence document.
design-bindings:
    node tools/design/check-tokens.mjs --write-bindings

# What each STALE `ledger@<revision>:<id>` citation points at, then and now.
#
# B4 NOW CALLS THIS (Q21). It used to assert revision CURRENCY as a proxy for
# "this citation still means what the comment says", which never missed a
# meaning change and fired on every citation at every ingest regardless of what
# the round touched — three consecutive rounds turned the same five tx-detail
# sites red while re-reviewing debugger triples, all SAFE-RESTAMP every time.
# `tools/design/lib/citation-meaning.mjs` is the shared half; B4 fails only on
# MEANING-CHANGED, on an id that has left the ledger, and on a revision not in
# history.
#
# This command stays, and is still the thing to run when B4 is red: it prints
# the two texts side by side so the reader can see WHAT changed rather than
# being told THAT something did.
#
# Prints the finding as it stood at the cited revision beside the finding at
# that id now, and classifies each site SAFE-RESTAMP or MEANING-CHANGED.
design-citations:
    node tools/design/citation-evidence.mjs

# Proof that the token lint DECIDES: every rule driven against the real product
# source carrying one deliberate violation, restored byte-identically after.
design-selftest:
    node tools/design/check-tokens-selftest.mjs

# verify_foundations_round_reaches_bar — the gate narrowed to the foundations
# criteria, with the FULL gate reported alongside it and never in place of it.
review-gate-foundations args="":
    node tools/capture/gate.mjs --foundations {{args}}

# Every VD.2 design check, including the ones that need a build. Run
# `cd client && just export` first — `design-check` passes --require-built and
# fails, rather than skipping, when there is no dist/ to cross-check.
design-verify: design-selftest design-check

# Live-reload dev server for the IsoNim client site. Runs the client's real
# static exporter, serves client/dist/, and reloads every open tab on any edit
# under client/src or src/ (the shared contract + demo generator). Delegates to
# the client workspace so paths resolve from there. `just dev [PORT] [HOST]`.
dev *ARGS:
    cd client && just dev {{ARGS}}

# Build the CLI binaries.
build:
    nim c --hints:off -d:release -o:blocktracer-demo-gen src/blocktracer_demo_gen.nim
    nim c --hints:off -d:release -o:blocktracer-validate src/blocktracer_validate.nim
    nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim
