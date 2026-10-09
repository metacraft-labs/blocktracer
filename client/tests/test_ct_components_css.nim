## The CodeTracer component port, asserted as a PORT and not as a stylesheet.
##
## `components/ct_components_css` compiles the vendored `.styl` files under
## `src/debugger/vendor/frontend/styles/components/` into the
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
    ##
    ## STATED AS A RELATIONSHIP, NOT AS A COUNT, and the history is the reason.
    ## This was `sources.len == 6`, the count the port landed with (`40db9e8`),
    ## and it went RED when `tab.styl` (`b6093f5`) and `shared_widgets.styl`
    ## were vendored — i.e. it failed for the one change it should have been silent
    ## about, and it would have been silent about the change it exists to
    ## catch, because a sheet that compiled to nothing leaves `sources.len`
    ## exactly where it was. A literal count is also the restatement of a
    ## declaration this module's header forbids: `vendoredSources()` IS the
    ## list, so `== 8` asserts nothing about the port.
    ##
    ## The claim instead is that the two SIDES agree: one vendored source, one
    ## provenance header in the emitted stylesheet. That is bidirectional — a
    ## sheet that compiled to nothing loses its header while keeping its row,
    ## and a header with no sheet behind it loses its row while keeping its
    ## header — and neither direction needs a number anybody maintains.
    let sources = vendoredSources()
    let headers = codetracerComponentCss.count(
      "ported verbatim from CodeTracer ")
    check headers == sources.len
    # …and a floor, so the equality cannot be satisfied by both sides
    # collapsing to zero. Four, which is well under the six this port landed
    # with (`40db9e8`) and the eight it carries now: a floor exists to refuse
    # a 0 == 0 pass, so it is set where no honest re-vendor can reach it and
    # nobody has to move it when one arrives.
    check sources.len >= 4
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
    ## TWO FAMILIES are legitimate, and between them they have four markers:
    ##
    ##   * `ct-images-*` — CodeTracer's own SVG asset handles, which this site
    ##     does not ship.
    ##
    ##   * the theme-file constants, `LAYOUT_*` / `RR_TICKS_*` /
    ##     `TOOLTIP_DELAY_TIMER` / `SEARCHED_TOKEN_COLOR`. Four markers, one
    ##     family: every one of them is assigned in
    ##     `src/frontend/styles/defaults.styl` or in a `default_*_theme.styl`
    ##     beside it, and this port vendors `styles/components/` only. The
    ##     reason is the family's and not each marker's, which is why the
    ##     family is what this list is about.
    ##
    ## Anything else is a defect, and a `colors-*` row is the SPECIFIC defect
    ## this notices: upstream's generated token layer resolves every one of its
    ## role names at the pinned commit, so an unresolved `colors-*` is a
    ## missing row in `Bridge` and therefore a declaration of upstream's that
    ## this port has silently stopped emitting. Four of them were on this list
    ## — `border-contrast`, `divider-primary`, `surface-base-raised`,
    ## `surface-input-default` — which cost a tab's hover underline, a toolbar
    ## divider and the dropdown menu's whole surface.
    const Allowed = ["ct-images-", "LAYOUT_", "RR_TICKS_",
                     "TOOLTIP_DELAY_TIMER", "SEARCHED_TOKEN_COLOR"]
    for u in ctPortReport().unresolved:
      var ok = false
      for marker in Allowed:
        if marker in u: ok = true
      if not ok: echo "  unresolved outside both families: ", u
      check ok

  test "every dropped rule is dropped ON PURPOSE, with a reason":
    ## A silent drop is the failure this whole module is built to avoid, so
    ## every row the port reports has to be ACCOUNTED FOR.
    ##
    ## THIS WAS `rep.dropped.len == Dropped.len` AND THE ARITHMETIC WAS NEVER
    ## TRUE. It measured 14 against 9, and all 14 were accounted for:
    ##
    ##   * 10 rows come from the 9 declared keys, because one key legitimately
    ##     matches TWO rules. `@media (prefers-reduced-motion: reduce)` occurs
    ##     in `golden_layout.styl` and in `shared_widgets.styl`, the key IS the
    ##     selector text, and the entry's own declared reason says so in words.
    ##     A table keyed by selector text can never be counted one-to-one
    ##     against rules.
    ##
    ##   * 4 rows are a DIFFERENT MECHANISM that arrived later: a build
    ##     condition (`if IS_EXTENSION` / `if !IS_EXTENSION`) is reported as a
    ##     drop whether or not its arm was taken, and `Dropped` has nothing to
    ##     do with it. Padding `Dropped` to 14 would have declared four rules
    ##     dropped that are not, and bumping the 9 to 14 would have been a
    ##     number to re-bump on the next conditional either way.
    ##
    ## So the claim is the one the count was reaching for, in both directions:
    ## every reported row is either a declared key or a self-describing
    ## conditional, AND every declared key is used by at least one row — so a
    ## key left behind for a rule upstream has deleted goes red rather than
    ## rotting in the table.
    let rep = ctPortReport()
    # Not vacuous: the port drops rules, and a report with none would mean the
    # drop mechanism had stopped running rather than that nothing is dropped.
    check rep.dropped.len > 0
    var usage = initTable[string, int]()
    for (key, _) in Dropped: usage[key] = 0
    for d in rep.dropped:
      check " — " in d               # the reason is present
      check d.startsWith("src/frontend/styles/components/")
      # `origin:line  <text> — <reason>`; the text is what is matched.
      let body = d[d.find("  ") + 2 ..< d.find(" — ")]
      if body in usage:
        inc usage[body]
      else:
        # The only other way out is a build condition, which names its own
        # condition and whether the arm was taken. Anything else is the silent
        # drop this module exists to prevent.
        check body.startsWith("if ")
        check ("— taken (" in d) or ("— not taken (" in d)
    for key, uses in usage.pairs:
      if uses == 0: echo "  declared Dropped key matches no rule: ", key
      check uses > 0

  test "every font family a vendored rule names is rebound to a face we serve":
    ## The one place the two products spell the same face differently:
    ## CodeTracer's `.styl` names `"SpaceGrotesk"` / `"SpaceMono"`, and
    ## `components/styles.nim` declares `'Space Grotesk Variable'` /
    ## `'Space Mono'`. Left alone the ported rules would fall back to the UA
    ## default — a regression dressed as fidelity.
    ##
    ## ASSERTED AGAINST THE VENDORED SOURCE rather than against a fixed list of
    ## aliases, and that is the whole point of the loop: which faces the
    ## vendored bytes actually name is upstream's decision and it MOVES. At one
    ## pin every live `font-family` line named SpaceGrotesk, because upstream
    ## had moved `.data-table` and `button` off SpaceMono; at the pin this tree
    ## carries, `shared_widgets.styl` names SpaceMono again. A test that had
    ## asserted the sans binding by name would have gone on passing through
    ## both moves while the mono binding was unexercised in one of them.
    ##
    ## So the REPLACEMENT is derived from the same table the substitution is:
    ## each spelling the sources name must be absent from the output and its
    ## own declared replacement present. Nothing below spells a family.
    var wanted: seq[string]
    for src in vendoredSources():
      for (spelling, _) in Aliases:
        if spelling in src.text and spelling notin wanted:
          wanted.add spelling
    check wanted.len > 0
    for spelling in wanted:
      # the spelling is gone from the output…
      check spelling notin codetracerComponentCss
      # …and replaced by the family this site's own @font-face block declares,
      # which is the row `Aliases` carries for it.
      for (alias, replacement) in Aliases:
        if alias == spelling:
          check replacement in codetracerComponentCss

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

suite "url() — the nine icons that shipped as 404s":
  ## THE MEASUREMENT THIS SUITE EXISTS FOR. The transpiler used to pass `url()`
  ## through unchanged, and two vendored sheets name their icons relative to the
  ## SHEET's place in CodeTracer's source tree. The compiled stylesheet is
  ## served from `/_a/<hash>.css`, so a browser resolved
  ## `url("../../../public/resources/origin-icons/sigma.svg")` to
  ## `/public/resources/origin-icons/sigma.svg` — a path this site has never
  ## published. 9 of the 13 `url()`s in the shipped sheet were a 404 for every
  ## visitor, and all 9 sat inside the `[data-register="debugger"]` scope, i.e.
  ## the debugger panels that are the whole visual-parity goal.
  ##
  ## The fix is in the transpiler and NOT in the vendored bytes: those are
  ## hashed against the pinned commit by `ci/test/ct-styles-vendor.sh`, so a
  ## hand edit would fail that gate by construction and be reverted by the next
  ## re-vendor besides. Where a file is PUBLISHED is a build decision, and that
  ## is what `StylPort.assetUrls` carries.

  proc bareProbe(assets: OrderedTable[string, string]): StylPort =
    result.bridge = initOrderedTable[string, string]()
    result.literalAliases = initOrderedTable[string, string]()
    result.dropRules = initOrderedTable[string, string]()
    result.assetUrls = assets

  test "the shipped stylesheet carries no relative url at all":
    ## The defect, stated as the property that forbids it. Measured by COUNTING
    ## rather than by naming the nine: a tenth icon arriving in a re-vendor must
    ## fail here if it is unplaced, which a list of nine spellings would not
    ## notice.
    var relatives = 0
    var placed = 0
    var i = 0
    while true:
      let hit = debugRouteCss.find("url(", i)
      if hit < 0: break
      let close = debugRouteCss.find(')', hit + 4)
      check close > hit
      let payload = debugRouteCss[hit + 4 ..< close].strip(chars = {'"', '\'', ' '})
      if payload.startsWith("/assets/ct-icons/"): inc placed
      elif not payload.startsWith("/") and not payload.startsWith("data:") and
           not payload.startsWith("http"):
        inc relatives
        echo "  unplaced url: ", payload
      i = close + 1
    check relatives == 0
    # Nine: the exact set that published broken before this change.
    check placed == 9

  test "every placed url names a row of the vendored-icon table":
    ## The two halves have to agree: `ctIconUrls()` is what the port was built
    ## with, so a url in the output that is not one of its values would mean the
    ## rewrite invented a path.
    let published = block:
      var s: seq[string] = @[]
      for _, url in ctIconUrls().pairs: s.add url
      s
    check published.len == 9
    for url in published:
      check url.startsWith("/assets/ct-icons/")
      check ("url(\"" & url & "\")") in debugRouteCss

  test "a vendored relative url is rewritten to the published copy":
    var assets = initOrderedTable[string, string]()
    assets["origin-icons/sigma.svg"] = "/assets/ct-icons/origin-icons/sigma.svg"
    var rep = StylReport()
    let css = transpile(@[StylSource(origin: "probe.styl", text:
      ".x\n  mask-image: url(\"../../../public/resources/origin-icons/sigma.svg\")\n")],
      bareProbe(assets), rep)
    check "url(\"/assets/ct-icons/origin-icons/sigma.svg\")" in css
    check "public/resources" notin css

  test "the two sheets' different ascent depths map to the same place":
    ## `button.styl` climbs three levels and `shared_widgets.styl` two, for the
    ## same upstream directory, because the sheets sit at different depths. A
    ## rewrite written against the depth would have placed one and broken the
    ## other — which is why the match is on the `public/resources/` tail.
    var assets = initOrderedTable[string, string]()
    assets["shared/noir_logo_dark_theme.svg"] =
      "/assets/ct-icons/shared/noir_logo_dark_theme.svg"
    var rep = StylReport()
    let css = transpile(@[StylSource(origin: "probe.styl", text:
      ".a\n  content: url(\"../../public/resources/shared/noir_logo_dark_theme.svg\")\n" &
      ".b\n  content: url(\"../../../../public/resources/shared/noir_logo_dark_theme.svg\")\n")],
      bareProbe(assets), rep)
    check css.count("url(\"/assets/ct-icons/shared/noir_logo_dark_theme.svg\")") == 2

  test "a url with no vendored file is a BUILD ERROR, not a pass-through":
    ## THE WHOLE LESSON OF THE DEFECT. The nine broken urls survived because
    ## nothing in the pipeline ever refused one. A transpiler that passes an
    ## unplaceable url through is how a 404 reaches production, so it raises —
    ## and the message names the missing key and where to vendor it.
    var rep = StylReport()
    expect StylError:
      discard transpile(@[StylSource(origin: "probe.styl", text:
        ".x\n  mask-image: url(\"../../public/resources/origin-icons/nope.svg\")\n")],
        bareProbe(initOrderedTable[string, string]()), rep)

  test "a relative url outside the vendored shape is a BUILD ERROR too":
    ## The mapping is total, not just keyed. A relative url of ANY other shape
    ## is resolved against `/_a/` by the browser and cannot reach anything this
    ## site publishes, so guessing at it would be the same silence by a
    ## different route.
    var rep = StylReport()
    expect StylError:
      discard transpile(@[StylSource(origin: "probe.styl", text:
        ".x\n  background: url(\"img/spinner.gif\")\n")],
        bareProbe(initOrderedTable[string, string]()), rep)

  test "absolute, data: and off-origin urls are left exactly as written":
    ## The false-positive direction. A rewrite that touched these would break
    ## `@font-face`, which names `/assets/fonts/...` directly — and a gate that
    ## cries wolf is a gate that gets switched off.
    var rep = StylReport()
    let css = transpile(@[StylSource(origin: "probe.styl", text:
      ".a\n  src: url(/assets/fonts/SpaceMono-Regular.ttf)\n" &
      ".b\n  background: url(\"data:image/svg+xml,%3Csvg%2F%3E\")\n" &
      ".c\n  background: url(https://cdn.example.com/x.png)\n" &
      ".d\n  mask: url(#clip)\n")],
      bareProbe(initOrderedTable[string, string]()), rep)
    check "url(/assets/fonts/SpaceMono-Regular.ttf)" in css
    check "url(\"data:image/svg+xml,%3Csvg%2F%3E\")" in css
    check "url(https://cdn.example.com/x.png)" in css
    check "url(#clip)" in css

suite "reachability — a rule that was NOT dropped can match something":
  ## THE CONVERSE OF `Dropped`, AND THE ASSERTION THAT WOULD HAVE CAUGHT THREE
  ## DEFECTS.
  ##
  ## `Dropped` records the rules the port does not emit, and the arm above
  ## asserts every reported drop is deliberate and reasoned. Nothing asserted
  ## the other direction: that a rule which was KEPT can actually match
  ## markup. So a rule could be vendored, transpiled, scoped, served and
  ## matched by nothing, and the only evidence either way was that somebody had
  ## once looked. Three defects came of it, two of them reported to the owner as
  ## fixed:
  ##
  ##   1. `.component-container` — CodeTracer's panel surface, served while
  ##      `grep -c component-container` over `components/debugger.nim` and
  ##      `pages/debug.nim` was 0.
  ##   2. the nine vendored icons — their `url()`s fixed from 404s to 200s
  ##      while ZERO of their nine selectors is emitted anywhere, measured over
  ##      349 built pages and all three JS bundles, raw and char-code-decoded.
  ##   3. `.separate-bar` and `.dropdown-list` — both given colour bindings,
  ##      both matching zero elements.
  ##
  ## THIS HALF OF THE GATE IS THE HALF THAT NEEDS NO BUILD. It asserts that
  ## `ct_css_reach.txt` ACCOUNTS FOR everything the port emits — every class,
  ## `[class*=]` substring, id and element, under exactly one row. The other
  ## half, `tools/ci/check-css-reachable.mjs`, asserts the rows are TRUE of the
  ## exported site. Neither is the gate alone: this one says the register is
  ## total, that one says it is not lying, and the claim the three defects
  ## needed is their composition.
  ##
  ## Which is also why this arm is HERE and not in a harness of its own: the
  ## register's totality is a property of the compiled stylesheet, which is
  ## this suite's subject and is a `const` it already reads. It runs in
  ## seconds, it is first in `just test`, and a re-vendor that introduces an
  ## unclassified selector fails here before anything renders.

  test "the register parses, and parses to rows rather than to nothing":
    let rows = reachRegister()
    # A floor, not a count: the register is expected to grow with every
    # re-vendor, and the number this refuses is zero — a parser that silently
    # matched nothing would make every claim below vacuously true.
    check rows.len >= 60
    var live, inert = 0
    for r in rows:
      check r.pattern.len > 0
      # The reason is the whole value of a row, exactly as it is for
      # `Dropped`. A short one is a row nobody wrote a reason for.
      check r.reason.len > 40
      if r.verdict == rvLive: inc live else: inc inert
    check live > 0
    check inert > 0

  test "every selector the port emits is accounted for, under exactly one row":
    ## THE ASSERTION. Not "at least one row" — exactly one — so a reader
    ## looking for why a class is inert finds one answer and two families
    ## cannot quietly overlap.
    let rows = reachRegister()
    let items = ctPortItems()
    # Not vacuous. The port names 160 classes at this pin; 100 is well under
    # that and well over zero, which is the number this floor exists to
    # refuse. An extractor that silently matched nothing would otherwise make
    # the loop below pass by having nothing to loop over.
    check items.len >= 150
    var byKind: array[PortItemKind, int]
    for it in items: inc byKind[it.kind]
    for k in PortItemKind:
      if byKind[k] == 0: echo "  no inventory item of kind ", k
      check byKind[k] > 0
    var unaccounted, ambiguous = 0
    for it in items:
      let hits = reachRowsFor(rows, it)
      if hits.len == 0:
        inc unaccounted
        echo "  NOT in ct_css_reach.txt: ", it.kind, " ", it.name,
             "   (e.g. ", it.sample, ")"
      elif hits.len > 1:
        inc ambiguous
        var pats: seq[string]
        for h in hits: pats.add rows[h].pattern
        echo "  covered by ", hits.len, " rows: ", it.kind, " ", it.name,
             " -> ", pats.join(", ")
    check unaccounted == 0
    check ambiguous == 0

  test "no row rots: every row covers something the port still emits":
    ## The direction `Dropped`'s own arm added for the same reason — a key
    ## left behind for a rule upstream has deleted goes red rather than
    ## sitting in the table being read as a reason for something.
    let rows = reachRegister()
    let items = ctPortItems()
    var covers = newSeq[int](rows.len)
    for it in items:
      for h in reachRowsFor(rows, it): inc covers[h]
    for i, n in covers:
      if n == 0:
        echo "  row covers nothing the port emits: ct_css_reach.txt:",
             rows[i].line, "  ", rows[i].pattern
      check n > 0

  test "the three defects are each named by a row, and on the right side":
    ## The register is data, so the three subjects can be asserted BY NAME
    ## without restating a declaration. `.component-container` is LIVE and
    ## must stay LIVE; the nine icons' selectors and the two dead rules are
    ## INERT and must say so rather than being absent.
    let rows = reachRegister()
    proc verdictOf(kind: PortItemKind; name: string): seq[ReachVerdict] =
      for r in rows:
        if r.kind == kind and matchesPattern(r.pattern, name):
          result.add r.verdict
    check verdictOf(pikClass, "component-container") == @[rvLive]
    for dead in ["ct-origin-badge", "ct-origin-badge-icon",
                 "ct-origin-icon-sigma", "ct-origin-icon-hourglass",
                 "value-history-button", "custom-noir-icon",
                 "separate-bar", "dropdown-list"]:
      check verdictOf(pikClass, dead) == @[rvInert]

  test "a state pseudo-class is not an item, and a descendant class still is":
    ## The hole this gate must not have. `:hover`, `:focus-visible`,
    ## `:disabled`, `:target` and `[data-selected]` cannot be found in static
    ## markup, so a rule on `X:hover` is an item for `X` alone. That excuse
    ## must NOT reach `.ct-origin-icon-sigma .ct-origin-badge-icon`, which is a
    ## DESCENDANT selector and is two items.
    var items: seq[PortItem]
    scanSelector(".ct-tab:hover:not([data-disabled=\"true\"])", items)
    check items.len == 1
    check items[0].kind == pikClass
    check items[0].name == "ct-tab"

    items = @[]
    scanSelector(".ct-origin-icon-sigma .ct-origin-badge-icon", items)
    check items.len == 2
    var names: seq[string]
    for it in items: names.add it.name
    check "ct-origin-icon-sigma" in names
    check "ct-origin-badge-icon" in names

    # `:not()` is the one nesting that must NOT yield an item: the rule
    # matches when the class is ABSENT, so requiring it to be emitted would be
    # backwards. `:has()` is the opposite and is descended into.
    items = @[]
    scanSelector(".lm_tab:not(.lm_active)", items)
    names = @[]
    for it in items: names.add it.name
    check names == @["lm_tab"]

    items = @[]
    scanSelector(".ct-counterexample:has(> .ct-counterexample-closed)", items)
    names = @[]
    for it in items: names.add it.name
    check "ct-counterexample" in names
    check "ct-counterexample-closed" in names

    # An element is an item only for a selector that names nothing else —
    # `.lm_tab span` asks nothing of `span` that `.lm_tab` does not.
    items = @[]
    scanSelector("[data-register=\"debugger\"] .lm_tab span", items)
    check items.len == 1
    check items[0].kind == pikClass

    items = @[]
    scanSelector("[data-register=\"debugger\"] button:disabled", items)
    check items.len == 1
    check items[0].kind == pikElement
    check items[0].name == "button"

  test "a `[class*=]` substring is an item of its own, honestly":
    ## The port emits twenty-one of them — `button.styl` crosses three button
    ## shapes with five sizes and three prominences and addresses each cell
    ## with one. They are not declared out of scope: a `[class*="S"]` matches
    ## a class attribute containing `S` anywhere, which is a question the
    ## markup can answer, so they are items and the register partitions them
    ## like any other.
    var items: seq[PortItem]
    scanSelector("[data-register=\"debugger\"] [class*=\"ct-button-xl-\"]", items)
    check items.len == 1
    check items[0].kind == pikClassPart
    check items[0].name == "ct-button-xl-"
    let rows = reachRegister()
    var parts = 0
    for it in ctPortItems():
      if it.kind == pikClassPart: inc parts
    check parts >= 15
    # …and the four that DO match are LIVE, which is what makes the other
    # seventeen a measurement rather than a blanket.
    var livePartRows = 0
    for r in rows:
      if r.kind == pikClassPart and r.verdict == rvLive: inc livePartRows
    check livePartRows > 0

  test "the pattern matcher is a glob and not a substring search":
    ## `*` is the only metacharacter. A row written `ct-origin-*` must not
    ## quietly cover `my-ct-origin-thing`, because a row that covers more than
    ## its reason describes is how a register stops being evidence.
    check matchesPattern("ct-origin-*", "ct-origin-badge")
    check matchesPattern("ct-origin-*", "ct-origin-icon-sigma")
    check not matchesPattern("ct-origin-*", "x-ct-origin-badge")
    check matchesPattern("dt-*", "dt-scroll-body")
    check not matchesPattern("dt-*", "dts_label")
    check matchesPattern("lm_tab", "lm_tab")
    check not matchesPattern("lm_tab", "lm_tabs")
    check matchesPattern("*-empty", "problems-empty")
    check not matchesPattern("*-empty", "empty-overlay")
