## The CodeTracer component port, asserted as a PORT and not as a stylesheet.
##
## `components/ct_components_css` compiles six vendored `.styl` files into the
## CSS this site serves. The vendor gate (`ci/test/ct-styles-vendor.sh`) proves
## the INPUT is still upstream's bytes; this proves the OUTPUT is still a port
## of them. Those are different failures and neither catches the other: a
## transpiler that silently stopped emitting half the rules would leave the
## manifest perfectly green.
##
## The shape of every assertion here is the same, and it is the shape the port
## needs: a claim about the RELATIONSHIP between the vendored source and the
## emitted CSS, never a restatement of a declaration. Nothing below spells a
## colour, a radius or a length — the moment a test did, it would be the second
## hand-written copy of the rule and the divergence would be back, in the
## suite that exists to prevent it.

import std/[strutils, unittest, tables]
import ../src/design_system/ct_styl
import ../src/components/ct_components_css
import ../src/components/debugger_css

proc ruleCount(css, selectorFragment: string): int =
  for line in css.splitLines:
    let brace = line.find('{')
    if brace > 0 and selectorFragment in line[0 ..< brace]:
      inc result

suite "the CodeTracer component port — the rules are upstream's, compiled":

  test "every vendored stylesheet reaches the output, named by its upstream path":
    ## The provenance comment is the trace the port is required to keep: a rule
    ## in the shipped stylesheet is found upstream by reading down from the
    ## header above it. A file that compiled to nothing would have no header,
    ## which is what this notices.
    let sources = vendoredSources()
    check sources.len == 6
    for src in sources:
      check src.origin.startsWith("src/frontend/styles/components/")
      check src.text.len > 0
      check ("ported verbatim from CodeTracer " & src.origin) in
            codetracerComponentCss

  test "the port emits a substantial stylesheet, not a handful of rules":
    ## A floor, not an exact count — an exact count is a number somebody
    ## updates rather than a claim somebody checks. The floor is what
    ## distinguishes "the transpiler ran" from "the transpiler returned early".
    let rep = ctPortReport()
    check rep.rules > 150
    check rep.declarations > 500
    # …and the pane chrome specifically, which is the whole point.
    check ruleCount(codetracerComponentCss, ".lm_") > 25

  test "every selector is scoped to the debugger register":
    ## `components/layout.siteCss` inlines `debugRouteCss` on EVERY exported
    ## page, because the home page embeds a real session. The port carries bare
    ## element selectors — `button`, `input`, `tr`, `td`, `table` — so an
    ## unscoped rule here would restyle the whole explorer.
    var unscoped: seq[string]
    for line in codetracerComponentCss.splitLines:
      if line.len == 0 or line.startsWith("/*"): continue
      let brace = line.find('{')
      if brace < 0: continue
      for sel in line[0 ..< brace].split(','):
        if not sel.strip.startsWith("[data-register=\"debugger\"] "):
          unscoped.add sel.strip
    check unscoped.len == 0

  test "no raw design value survives the bridge":
    ## Every colour in the emitted CSS is a `var(--bt-*)`. This is the property
    ## that keeps the port inside `tools/design/check-tokens.mjs` rather than
    ## beside it, and it is asserted HERE as well as there because the port's
    ## input is a `.styl` file, which that checker does not read.
    for marker in ["colors-ui-", "colors-neutral-", "colors-brand-",
                   "ct-images-", "#282828", "#1b1b1b", "#444444"]:
      check marker notin codetracerComponentCss

  test "the unresolved list holds only the two families we expect":
    ## An identifier the bridge does not carry has its declaration DROPPED,
    ## which reproduces what upstream's own build does (Stylus emits an unknown
    ## bare identifier verbatim and the browser discards the declaration). That
    ## is only safe while the list is the SHORT one — otherwise a bridge row
    ## going missing would quietly unstyle a panel.
    ##
    ## Two families are legitimate: `ct-images-*`, CodeTracer's own SVG assets,
    ## which this site does not ship; and the three theme-file constants
    ## (`LAYOUT_*`, `RR_TICKS_*`, `TOOLTIP_DELAY_TIMER`) that live in files this
    ## port does not vendor. Anything else is a defect.
    for u in ctPortReport().unresolved:
      check "ct-images-" in u or "LAYOUT_" in u or "RR_TICKS_" in u or
            "TOOLTIP_DELAY_TIMER" in u

  test "every dropped rule is dropped ON PURPOSE, with a reason":
    ## `Dropped` is the only place a rule leaves the port, and each entry
    ## carries prose. A silent drop is the failure this whole module is built
    ## to avoid, so the count is pinned to the declared table.
    let rep = ctPortReport()
    check rep.dropped.len == Dropped.len
    for d in rep.dropped:
      check " — " in d               # the reason is present
      check d.startsWith("src/frontend/styles/components/")

  test "every font family a vendored rule names is rebound to a face we serve":
    ## The one place the two products spell the same face differently:
    ## CodeTracer's `.styl` names `"SpaceGrotesk"` / `"SpaceMono"`, and
    ## `components/styles.nim` declares `'Space Grotesk Variable'` /
    ## `'Space Mono'`. Left alone the ported rules would fall back to the UA
    ## default — a regression dressed as fidelity.
    ##
    ## ASSERTED AGAINST THE VENDORED SOURCE rather than against both aliases.
    ## At the pinned commit every one of the thirteen `font-family` lines in
    ## these six files names SpaceGrotesk — upstream moved `.data-table` and
    ## `button` off SpaceMono before this pin — so asserting that the mono
    ## binding appears in the OUTPUT would assert a rule upstream does not
    ## have. The mono alias stays declared as the guard for a re-vendor that
    ## brings SpaceMono back, and this loop is what would then require it.
    var wanted: seq[string]
    for src in vendoredSources():
      for (spelling, _) in Aliases:
        if spelling in src.text and spelling notin wanted:
          wanted.add spelling
    check wanted.len > 0
    for spelling in wanted:
      # the spelling is gone from the output…
      check spelling notin codetracerComponentCss
    # …and replaced by a family this site's own @font-face block declares.
    check "var(--bt-font-sans)" in codetracerComponentCss

  test "the active tab's rules are upstream's bytes, not a second copy":
    ## `activeTabCss()` re-emits every `.lm_active` rule under the
    ## `:target`-derived selectors a page with no JavaScript needs. The claim
    ## is that the DECLARATIONS are identical — if somebody ever re-typed them
    ## the two would drift, which is exactly the defect the port exists to end.
    let alias = activeTabCss()
    check alias.len > 0
    var upstreamBodies: seq[string]
    for line in codetracerComponentCss.splitLines:
      let brace = line.find('{')
      if brace > 0 and ".lm_active" in line[0 ..< brace]:
        upstreamBodies.add line[brace .. ^1]
    check upstreamBodies.len > 0
    # Every body in the alias set is one of upstream's, unchanged.
    for line in alias.splitLines:
      if line.len == 0: continue
      let brace = line.find('{')
      check brace > 0
      check line[brace .. ^1] in upstreamBodies
    # …and the set is complete: one alias rule per upstream rule per
    # activation condition — the no-fragment default plus one per tab
    # position. Counted over LINES rather than over bodies, because two
    # upstream rules legitimately share a body (`{display:none;}` switches off
    # both the left and the right connector) and a per-body count would read
    # that coincidence as a duplicate.
    var upstreamRuleLines = 0
    for line in codetracerComponentCss.splitLines:
      let brace = line.find('{')
      if brace > 0 and ".lm_active" in line[0 ..< brace]: inc upstreamRuleLines
    var aliasRuleLines = 0
    for line in alias.splitLines:
      if line.len > 0: inc aliasRuleLines
    check aliasRuleLines == upstreamRuleLines * (MaxStackTabs + 1)

  test "the port is in the shipped stylesheet, and it comes FIRST":
    ## Order is how the two layers divide: upstream's rules are emitted before
    ## BlockTracer's, so a BlockTracer rule can answer one at equal
    ## specificity by being later. Reversing it would make every
    ## no-counterpart rule in `debugger_css.nim` silently inert.
    check codetracerComponentCss in debugRouteCss
    check debugRouteCss.startsWith(codetracerComponentCss)

  test "the retired BlockTracer pane vocabulary is gone from the served CSS":
    ## The rules were DELETED, not left alongside. Leaving both is how the
    ## divergence comes back, and this stylesheet is inlined into every served
    ## page — so a comment that merely SPELLS a retired selector puts its text
    ## back into the bytes. `debugger_css.nim`'s retirement table is written
    ## without leading dots for exactly this assertion.
    for dead in [".pane{", ".panehead", ".panetitle", ".panebody", ".panenote",
                 ".stacktab", ".stackpanel", ".ln.stack"]:
      check dead notin debugRouteCss

suite "the Stylus subset — what it refuses, and why that matters":

  test "an unsupported construct raises rather than being skipped":
    ## A transpiler that quietly drops what it does not understand is how a
    ## port comes to differ from its origin with nobody noticing. Every
    ## construct outside the subset is a hard error, and the three that the
    ## vendored files actually contain are named in `Dropped` instead.
    var port: StylPort
    port.bridge = initOrderedTable[string, string]()
    port.literalAliases = initOrderedTable[string, string]()
    port.dropRules = initOrderedTable[string, string]()

    for bad in ["@media (min-width: 10px)\n  .x\n    color: red\n",
                ".x\n  some-mixin(1px)\n",
                "@keyframes spin\n  0%\n    opacity: 1\n"]:
      var rep = StylReport()
      expect StylError:
        discard transpile(@[StylSource(origin: "probe.styl", text: bad)],
                          port, rep)

  test "a dropped rule takes its whole subtree, and says so":
    var port: StylPort
    port.bridge = initOrderedTable[string, string]()
    port.literalAliases = initOrderedTable[string, string]()
    port.dropRules = initOrderedTable[string, string]()
    port.dropRules[".gone"] = "a reason"
    var rep = StylReport()
    let css = transpile(@[StylSource(origin: "probe.styl", text:
      ".kept\n  color: red\n\n.gone\n  color: blue\n\n  &:hover\n    color: teal\n")],
      port, rep)
    check ".kept{color:red;}" in css
    check "blue" notin css
    check "teal" notin css
    check rep.dropped.len == 1
    check "a reason" in rep.dropped[0]

  test "Stylus's bare selector-group form is one rule, not a lost line":
    ## `.ct-input-small` / `.ct-input-panel` on consecutive lines with one
    ## indented block is a GROUP in Stylus. A line-at-a-time reader drops the
    ## first, which would have silently unstyled half of `input.styl`.
    var port: StylPort
    port.bridge = initOrderedTable[string, string]()
    port.literalAliases = initOrderedTable[string, string]()
    port.dropRules = initOrderedTable[string, string]()
    var rep = StylReport()
    let css = transpile(@[StylSource(origin: "probe.styl", text:
      ".a\n.b\n  color: red\n")], port, rep)
    check ".a,.b{color:red;}" in css
    check rep.rules == 1
