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

# verify_capture_covers_named_view_list + verify_full_regen_removes_stale_images
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

# Emit the sub-agent prompts for one captured image, e.g.
#   just review-prompt "--view tx-detail --size wide --theme light --all"
review-prompt args="":
    node tools/capture/review-prompt.mjs {{args}}

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

# Build the CLI binaries.
build:
    nim c --hints:off -d:release -o:blocktracer-demo-gen src/blocktracer_demo_gen.nim
    nim c --hints:off -d:release -o:blocktracer-validate src/blocktracer_validate.nim
    nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim
