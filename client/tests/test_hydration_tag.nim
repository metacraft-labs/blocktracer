## The hydration bundle's `<script>` is EMITTED when a bundle is declared.
##
## Why this file exists, and why it is compiled twice.
##
## `debugLayout` built the tag as a top-level `if` inside a `ui:` block. `ui:`
## renders a top-level `if` as NOTHING — the SSR codegen returns nil for a node
## that is not a call — so the tag was silently dropped. The bundle was built,
## deployed and served at /assets/hydrate.js, and no page referenced it: every
## session on blocktracer.org was a still frame whose controls waited on an
## engine nothing would ever load.
##
## M9 met the identical defect in `debugCell`, where it emitted
## `<td class="act"></td>` for every row and removed the Debug affordance from
## the product. Same construct, same silent drop, twice.
##
## The existing suites assert the EMPTY case — a build with no bundle emits no
## executable script — and three of them say in prose what a build WITH one
## would emit. None of them checked. An assertion about the absence of a thing
## cannot catch a defect that makes the thing always absent, which is exactly
## the shape this project has now found seven times.
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
