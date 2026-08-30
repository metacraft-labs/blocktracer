## The hydration bundle's `<script>` is EMITTED when a bundle is declared.
##
## Why this file exists, and why it is compiled twice.
##
## The existing suites assert the EMPTY case — a build with no bundle emits no
## executable script — and three of them say in prose what a build WITH one
## would emit. None of them checked. An assertion about the absence of a thing
## cannot catch a defect that makes the thing always absent, which is exactly
## the shape this project has now found seven times. So this file compiles
## under `-d:hydrationBundle=…` and asserts the tag is PRESENT, which is the
## one direction nothing else covers.
##
## CORRECTION, 2026-08-30. This file was added by 9f551ec, which said the tag
## had been dropped by a top-level `if` inside a `ui:` block — the construct
## that cost M9 its `debugCell` Debug affordance. That is a real defect of the
## SSR codegen, and `components/layout.hydrationScriptTag` is still written to
## be immune to it, but it is NOT what happened here: the `if` in question was
## nested under `body:`, where `ssrChildrenExpr` renders it correctly, and the
## deploy that was diagnosed did serve
## `<script src="/assets/hydrate.js" defer="defer"></script>` on every debug
## and transaction page. The production symptom — sessions frozen with their
## controls waiting on an engine — came from /replay-engine/worker.js 404ing,
## and 0cb840e fixed that. See the correction in `layout.nim` for the evidence.
##
## The test stays regardless of which cause was real. It is the only assertion
## in the tree that a declared bundle is actually referenced, and the gap it
## covers is genuine even though the incident that prompted it was misread.
##
## Run under `-d:hydrationBundle=…` by `just test-hydration-tag`.

import std/[strutils, unittest]
import ../src/debugger/replay_engine
import ../src/components/layout

suite "the hydration bundle is referenced by the page that needs it":

  test "a declared bundle appears as a deferred script in the debug shell":
    # Guard the guard: if the define did not reach this compilation the test
    # below would pass vacuously on the empty branch, so fail loudly instead.
    check HydrationBundle.len > 0
    let html = debugLayout("t", "d", "<main>x</main>")
    # `defer=""`, not a bare `defer`: the tag is built by the isonim DSL rather
    # than concatenated, and the SSR codegen writes every attribute in the
    # quoted form. HTML defines the two as the same boolean attribute, and the
    # DSL is what makes the tag scannable by `tools/design/check-tokens.mjs`
    # A7 — a hand-built fragment is markup the token layer never sees.
    check "<script src=\"" & HydrationBundle & "\" defer=\"\"></script>" in html

  test "it is deferred and last in the body, so first paint is static":
    let html = debugLayout("t", "d", "<main>x</main>")
    let at = html.find("<script")
    check at > 0
    check "defer" in html[at .. min(at + 80, html.high)]
    # §7.0: no wasm on the critical path. A tag before the content would be
    # parsed before the frame the visitor came to read.
    check html.find("<main>x</main>") < at

  test "the explorer shell never carries it":
    # `pageLayout` has no session to hydrate; a script there is bytes fetched
    # to do nothing.
    check "<script" notin pageLayout("t", "d", "<main>x</main>")
