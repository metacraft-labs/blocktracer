# BlockTracer workspace commands.
# `just` recipes wrap the nimble tasks so the workspace has one entry point.

# Run the conformance + publisher test suites.
test:
    nim c -r --hints:off tests/tcontract.nim
    nim c -r --hints:off tests/tpublish.nim

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
capture-setup:
    cd tools/capture && npm install --no-audit --no-fund && npx playwright install chromium

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

# The tier-1 determinism canary, in the pinned container.
capture-canary-pinned:
    tools/capture/run-in-container.sh canary

# Full regeneration in the pinned container.
capture-pinned args="":
    tools/capture/run-in-container.sh capture {{args}}

# The gate a baseline comparison must pass before it may be believed.
capture-gate:
    node tools/capture/require-deterministic.mjs

# All four VD.0 verifications, end to end.
capture-selftest:
    node tools/capture/selftest.mjs

# Build the CLI binaries.
build:
    nim c --hints:off -d:release -o:blocktracer-demo-gen src/blocktracer_demo_gen.nim
    nim c --hints:off -d:release -o:blocktracer-validate src/blocktracer_validate.nim
    nim c --hints:off -d:release -o:blocktracer-publish src/blocktracer_publish.nim
