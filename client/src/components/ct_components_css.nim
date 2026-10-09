## CodeTracer's component stylesheets, served by BlockTracer.
##
## This module is the whole of what BlockTracer *decides*. The rules themselves
## are not here: they are the vendored `.styl` bytes under
## `../debugger/vendor/frontend/styles/components/`, byte-identical to the
## CodeTracer commit `ci/embed-sdk-pin.env` pins, and `design_system/ct_styl`
## compiles them. The argument for that mechanism — and for why adding Stylus
## to this build was the worse of the two honest options — is in `ct_styl.nim`'s
## own header.
##
## What is decided here is exactly three things, and each is data rather than
## prose so a test can read it:
##
##   1. `Bridge` — a CodeTracer role name → the `--bt-*` role that already
##      carries the same value. Both vocabularies are generated from the SAME
##      `codetracer-design-system` DTCG files (CodeTracer via
##      `styles/generated/{brand,alias,mapped}.styl`, BlockTracer via
##      `design_system/web.tokens.json`), so most rows are an EXACT ramp match
##      and the comment on each row names both positions. A row that is not
##      exact says so.
##
##   2. `Aliases` — the two font families, which are the one place the two
##      products spell the same face differently: CodeTracer's `.styl` names
##      `"SpaceGrotesk"`/`"SpaceMono"`, BlockTracer's `@font-face` block in
##      `components/styles.nim` declares `'Space Grotesk Variable'`/`'Space
##      Mono'`. Without the alias the ported rules would ask for a family this
##      site does not serve and fall back to the UA default — a regression,
##      dressed as fidelity.
##
##   3. `Dropped` — the rules BlockTracer does not emit, each with the reason.
##      Only two, and both are for markup that cannot exist on a route with no
##      JavaScript.
##
## ## The scope, and why it is not optional
##
## `components/layout.siteCss` inlines `debugRouteCss` on EVERY exported page,
## not just the debug route, because the home page embeds a real session. The
## port carries bare element selectors — `button`, `input`, `tr`, `td`, `table`
## — so unscoped it would restyle the whole explorer, which a different branch
## owns. Every selector is therefore prefixed with `[data-register="debugger"]`,
## which is set on `<html>` by the debug route (`components/layout.nim:266`) and
## on the embed's own wrapper by the home page (`pages/home.nim`). One prefix,
## applied in one pass by `ct_styl.scoped`, so nothing nested can escape it.
##
## ## What "unresolved" means, and why the list is short on purpose
##
## Three CodeTracer role names — `colors-ui-text-default-tab`,
## `colors-ui-text-default-placeholder`, `colors-ui-text-disabled-default` —
## are NOT DEFINED in CodeTracer's own generated token layer at the pinned
## commit. Stylus emits such an identifier verbatim and the browser then drops
## the declaration, so those rules have no effect in CodeTracer either; the
## port reproduces that by dropping them too, and records each one. The
## `ct-images-*` handles are CodeTracer's own SVG assets, which this site does
## not ship; their declarations drop for the same reason and with the same
## record. `ctPortReport()` is that record, and
## `client/tests/test_ct_components_css.nim` asserts the list holds only those
## two families — so a bridge row going missing shows up as a test failure
## rather than as a quietly unstyled panel.

import std/[tables, strutils]
import ../design_system/ct_styl

export StylReport

# ── the vendored sources, in `codetracer.styl`'s own import order ──────────
#
# `staticRead` rather than a runtime read: the exporter runs from a build
# directory that is not the source tree, and `debugRouteCss` is a `const` that
# roughly forty assertions in `client/tests/test_debug_route.nim` read directly.
# The bytes are therefore part of the compiled artefact, which is also what the
# vendor gate hashes.

const
  VendoredButton = staticRead(
    "../debugger/vendor/frontend/styles/components/button.styl")
  VendoredInput = staticRead(
    "../debugger/vendor/frontend/styles/components/input.styl")
  # `codetracer.styl` imports this between `input` and `notifications`. It is
  # the TAB IDIOM itself — the first review round found three different ones in
  # a single debugger screenshot (underline on the file tabs, a pill on the
  # pane tabs, boxed buttons on the frame selector), which is the thing the
  # operator's report named.
  VendoredTab = staticRead(
    "../debugger/vendor/frontend/styles/components/tab.styl")
  VendoredNotifications = staticRead(
    "../debugger/vendor/frontend/styles/components/notifications.styl")
  # `codetracer.styl` imports this between `notifications` and `data_tables`,
  # and the position is load-bearing: it declares `.component-container`, the
  # PANEL SURFACE every other component is drawn inside, so a component rule
  # meaning to override the surface has to arrive after it.
  VendoredSharedWidgets = staticRead(
    "../debugger/vendor/frontend/styles/components/shared_widgets.styl")
  VendoredDataTables = staticRead(
    "../debugger/vendor/frontend/styles/components/data_tables.styl")
  VendoredGoldenLayout = staticRead(
    "../debugger/vendor/frontend/styles/components/golden_layout.styl")
  # LAST, exactly as in `codetracer.styl`, and for the reason its own header
  # gives: the shared empty-state treatment has to win over the per-component
  # padding declared above it, and it wins by arriving later in the cascade.
  VendoredEmptyStates = staticRead(
    "../debugger/vendor/frontend/styles/components/empty_states.styl")

# ── the vendored ICONS the vendored sheets name ────────────────────────────
#
# `button.styl` and `shared_widgets.styl` reference nine SVGs by a path relative
# to the SHEET's place in CodeTracer's source tree — upstream's
# `url("../../../public/resources/origin-icons/sigma.svg")`. BlockTracer serves
# the compiled sheet from `/_a/<hash>.css`, so a browser resolved that to
# `/public/resources/origin-icons/sigma.svg`, which this site has never
# published: 9 of the 13 `url()`s in the built stylesheet were a 404 for every
# visitor, and all 9 sat inside the `[data-register="debugger"]` scope — the
# debugger panels, i.e. the whole visual-parity goal.
#
# The sheets are NOT edited to fix that. They are vendored byte-verbatim and
# `ci/test/ct-styles-vendor.sh` hashes them against the pinned commit, so a hand
# edit would fail that gate by construction and be reverted by the next
# re-vendor besides. Where a file is PUBLISHED is a BlockTracer build decision,
# and a build decision belongs in the port: `ct_styl.rewriteUrls` consumes the
# table below and RAISES on any relative url it does not find there.
#
# The icons themselves are vendored under `client/src/assets/ct-icons/`, from
# the same CodeTracer commit as the sheets; see that directory's README.

const
  CtIconVendorDir = "../assets/ct-icons"
    ## Relative to THIS file, for the compile-time existence proof below.
  CtIconPublishedRoot = "/assets/ct-icons"
    ## Where `static_export.copyStaticAssets` publishes that directory. The two
    ## halves are checked against each other by `tools/deploy/check-assets.mjs`
    ## A6 over the published bytes, which is the only place that can.

  CtVendoredIcons: array[9, tuple[group, file: string]] = [
    # `origin-icons/` — `button.styl`'s `.ct-origin-icon-*` badge masks.
    (group: "origin-icons", file: "clock-rewind.svg"),
    (group: "origin-icons", file: "door.svg"),
    (group: "origin-icons", file: "globe.svg"),
    (group: "origin-icons", file: "hourglass.svg"),
    (group: "origin-icons", file: "question.svg"),
    (group: "origin-icons", file: "quotation.svg"),
    (group: "origin-icons", file: "sigma.svg"),
    # `shared/` — `button.styl`'s `.value-history-button::before` and
    # `shared_widgets.styl`'s `.custom-noir-icon::before`.
    (group: "shared", file: "history_value_view_toggle_dark.svg"),
    (group: "shared", file: "noir_logo_dark_theme.svg"),
  ]
    ## The TOTAL list. A fixed-length `array` rather than a seq so that adding a
    ## row without saying so is a compile error here too, and so the count is
    ## part of the declaration rather than something a reader has to tally.

const CtIconRows = static:
  ## `(<group>/<file>, published URL, byte count)` for every row, computed in a
  ## `static:` block so EVERY ROW'S BYTES ARE READ AT COMPILE TIME. That read is
  ## the existence proof and it is not optional: a row naming a file that is not
  ## vendored cannot compile, and `rewriteUrls` refusing an unlisted url closes
  ## the other direction, so the mapping is total in both.
  ##
  ## A zero-byte copy fails here too. `check-assets.mjs` A2/A6 would also catch
  ## it in the publish tree, but failing at the build is cheaper than failing at
  ## the gate, and the build is where the cause is.
  var rows: seq[tuple[key, url: string, bytes: int]] = @[]
  for (group, file) in CtVendoredIcons:
    let key = group & "/" & file
    let bytes = staticRead(CtIconVendorDir & "/" & key)
    doAssert bytes.len > 0,
      "vendored icon " & key & " is zero bytes; the copy step produced nothing"
    rows.add (key, CtIconPublishedRoot & "/" & key, bytes.len)
  rows

proc ctIconUrls*(): OrderedTable[string, string] =
  ## `<group>/<file>` → the published URL of BlockTracer's copy. This is what
  ## `StylPort.assetUrls` carries, and `client/tests/test_ct_components_css.nim`
  ## reads it to assert the two sheets' nine urls are all placed.
  result = initOrderedTable[string, string]()
  for (key, url, _) in CtIconRows:
    doAssert key notin result, "duplicate row in CtVendoredIcons: " & key
    result[key] = url

proc vendoredSources*(): seq[StylSource] =
  @[StylSource(origin: "src/frontend/styles/components/button.styl",
               text: VendoredButton),
    StylSource(origin: "src/frontend/styles/components/input.styl",
               text: VendoredInput),
    StylSource(origin: "src/frontend/styles/components/tab.styl",
               text: VendoredTab),
    StylSource(origin: "src/frontend/styles/components/notifications.styl",
               text: VendoredNotifications),
    StylSource(origin: "src/frontend/styles/components/shared_widgets.styl",
               text: VendoredSharedWidgets),
    StylSource(origin: "src/frontend/styles/components/data_tables.styl",
               text: VendoredDataTables),
    StylSource(origin: "src/frontend/styles/components/golden_layout.styl",
               text: VendoredGoldenLayout),
    StylSource(origin: "src/frontend/styles/components/empty_states.styl",
               text: VendoredEmptyStates)]

# ── 1. the identifier bridge ───────────────────────────────────────────────
#
# Read the comment on each row as: CodeTracer's ramp position at the pinned
# commit → BlockTracer's ramp position in the DARK theme, which is the
# debugger register's default. Where the two agree the row is marked `=`; where
# they do not, the row is bound by ROLE and the gap is stated. Light theme is
# BlockTracer's own and deliberately so: CodeTracer ships one theme, this
# register ships two, and binding to a role rather than to a hex is what keeps
# the light debugger working.

const Bridge*: seq[(string, string)] = @[
  # surfaces ────────────────────────────────────────────────────────────────
  # The relationship the port is really importing: CodeTracer's PANELS are
  # LIGHTER than the frame they float in (neutral-700 on neutral-900), which is
  # the inverse of what BlockTracer's debugger drew. Both sides of that
  # relationship are exact matches, so the inversion arrives intact.
  ("colors-ui-surface-primary-default", "var(--bt-surface-raised)"),      # neutral-900 = neutral-900
  ("colors-ui-surface-base-canvas", "var(--bt-surface-raised)"),          # neutral-900 = neutral-900
  ("colors-ui-surface-base-panel", "var(--bt-surface-sunken)"),           # neutral-700 = neutral-700
  ("colors-ui-surface-primary-secondary", "var(--bt-surface-sunken)"),    # neutral-700 = neutral-700
  ("colors-ui-surface-input-secondary", "var(--bt-surface-sunken)"),      # neutral-700 = neutral-700
  ("colors-ui-surface-primary-tertiary", "var(--bt-surface-hover)"),      # neutral-650 = neutral-650
  ("colors-ui-surface-primary-secondary-hover", "var(--bt-surface-hover)"), # neutral-650 = neutral-650
  # neutral-750: no BlockTracer surface sits between raised (900) and sunken
  # (700). Bound to the overlay rung (850), which is the only surface that is a
  # step lighter than raised, so the hover still reads as a lift.
  ("colors-ui-surface-primary-default-hover", "var(--bt-surface-overlay)"),
  # neutral-550: above every BlockTracer surface rung. Bound to the hover
  # surface (650), which collapses tertiary and tertiary-hover to one value.
  # Stated rather than hidden: it is the one row in this table that loses a
  # distinction upstream makes.
  ("colors-ui-surface-primary-tertiary-hover", "var(--bt-surface-hover)"),
  ("colors-ui-surface-primary-disabled", "var(--bt-action-disabled-bg)"), # role
  ("colors-ui-surface-action-primary", "var(--bt-action-bg)"),            # role: brand-500 -> brand-600
  ("colors-ui-surface-action-primary-hover", "var(--bt-action-bg-hover)"), # role: brand-700 -> brand-500
  # The alert surfaces bind by ROLE, not by ramp. CodeTracer fills an alert
  # with a saturated 700; BlockTracer's status surfaces are a neutral fill with
  # a coloured border, and that treatment is the one its own contrast rounds
  # graded. Importing the fill would re-open a measured finding.
  ("colors-ui-surface-alert-error", "var(--bt-status-danger-bg)"),
  ("colors-ui-surface-alert-warning", "var(--bt-status-warning-bg)"),
  ("colors-ui-surface-alert-success", "var(--bt-status-success-bg)"),
  ("colors-ui-surface-alert-information", "var(--bt-status-info-bg)"),

  # text ────────────────────────────────────────────────────────────────────
  ("colors-ui-text-primary-body", "var(--bt-text-strong)"),               # neutral-50 = neutral-50
  ("colors-ui-text-primary-label", "var(--bt-text-default)"),             # neutral-150 -> neutral-100
  ("colors-ui-text-primary-body-subtle", "var(--bt-text-muted)"),         # neutral-200 -> neutral-250
  ("colors-ui-text-primary-label-subtle", "var(--bt-text-subtle)"),       # neutral-300 = neutral-300
  ("colors-ui-text-primary-caption-subtle", "var(--bt-text-disabled)"),   # neutral-400 = neutral-400
  ("colors-ui-text-primary-disabled", "var(--bt-text-disabled)"),         # neutral-400 = neutral-400
  ("colors-ui-text-primary-active", "var(--bt-accent-default)"),          # role: brand-500 -> brand-400
  ("colors-ui-text-on-action-primary", "var(--bt-action-fg)"),            # role
  ("colors-ui-icon-primary-default", "var(--bt-text-default)"),           # neutral-100 = neutral-100
  ("colors-ui-text-error-primary", "var(--bt-status-danger-fg)"),
  ("colors-ui-text-warning-primary", "var(--bt-status-warning-fg)"),
  ("colors-ui-text-success-primary", "var(--bt-status-success-fg)"),
  ("colors-ui-text-information-primary", "var(--bt-status-info-fg)"),

  # borders ─────────────────────────────────────────────────────────────────
  ("colors-ui-border-primary", "var(--bt-border-default)"),               # neutral-450 = neutral-450
  ("colors-ui-border-tertiary", "var(--bt-border-subtle)"),               # neutral-700 = neutral-700
  ("colors-ui-border-primary-hover", "var(--bt-border-strong)"),          # neutral-350 -> neutral-400
  ("colors-ui-border-secondary", "var(--bt-border-subtle)"),              # neutral-600 -> neutral-700
  ("colors-ui-border-action", "var(--bt-border-accent)"),                 # brand-500 = brand-500
  ("colors-ui-border-disabled", "var(--bt-action-disabled-border)"),      # role
  ("colors-ui-border-focus", "var(--bt-focus-ring)"),                     # role: blue-500 -> information-400
  ("colors-ui-border-error", "var(--bt-status-danger-border)"),
  ("colors-ui-border-warning", "var(--bt-status-warning-border)"),
  ("colors-ui-border-success", "var(--bt-status-success-border)"),
  ("colors-ui-border-information", "var(--bt-status-info-border)"),

  # the one constant declared in a file this port does not carry ────────────
  # `EMPTY_OVERLAY_SIDE_GAP = 2.5rem`, `src/frontend/styles/components/
  # shared_widgets.styl:328` at the pinned commit. Vendoring that file for one
  # assignment would drag in several hundred rules for markup this site does
  # not have; naming its origin here is the cheaper honest option. 2.5rem is
  # `--bt-space-2xl` (scale.950 = 40px).
  ("EMPTY_OVERLAY_SIDE_GAP", "var(--bt-space-2xl)"),
]

# ── 2. the two literal aliases ─────────────────────────────────────────────

const Aliases*: seq[(string, string)] = @[
  ("\"SpaceGrotesk\"", "var(--bt-font-sans),var(--bt-font-sans-fallback)"),
  ("\"SpaceMono\"", "var(--bt-font-mono),var(--bt-font-mono-fallback)"),
]

# ── 3. the rules BlockTracer does not emit ─────────────────────────────────

const Dropped*: seq[(string, string)] = @[
  (".lm_splitter.lm_dragging",
   "there is no drag on a route with no JavaScript, so the class is never " &
   "applied — and it carries the ONE raw hex colour upstream writes in these " &
   "six files, which `test_static_export`'s shipped-rules scan rejects (and " &
   "which is not quoted here, because check-tokens.mjs A1 reads this file's " &
   "own string literals). Dropping a rule nothing can match is how both stay " &
   "true without editing upstream's bytes or weakening either gate"),
  (".lm_header .lm_tab .lm_close_tab",
   "a tab this route cannot close: the strip is `:target` links, there is no " &
   "JavaScript to remove a panel, and the rule calls the `tab-icon()` mixin " &
   "over a CodeTracer SVG this site does not ship"),
  (".lm_header .lm_tab .lm_pin_tab",
   "same: no pinning without a layout manager, and the same mixin over the " &
   "same unavailable asset"),
  (".lm_header .lm_tab:not(.lm_active)",
   "styles only the two icons above, which are not emitted"),
  (".lm_header .lm_tab.lm_tab_busy .lm_title",
   "drives the keyframes dropped below; a rule naming an animation that is " &
   "not emitted is a dangling reference nothing would ever notice"),
  ("@keyframes lm-tab-busy-pulse",
   "the busy-tab animation is driven by `setCalltraceTabBusy` in CodeTracer's " &
   "renderer; a static page has no panel that can become busy"),
  ("@media (prefers-reduced-motion: reduce)",
   "TWO rules share this key, in golden_layout.styl and shared_widgets.styl, " &
   "and the key is the selector text so one entry drops both. In " &
   "golden_layout its only content is the busy-tab rule above; in " &
   "shared_widgets it is the reduced-motion arm of the dropdown reveal, whose " &
   "keyframes are dropped below. Neither has anything left to say once the " &
   "animation it modifies is not emitted"),
  ("@keyframes ct-dropdown-reveal",
   "the dropdown reveal animation plays when a menu OPENS; this route's " &
   "menus are `:target` links with no JavaScript to open them, so the " &
   "animation has no moment at which it could run"),
  ("@keyframes ct-line-flash",
   "the flash that marks a line the debugger has just jumped to. It is " &
   "started by the renderer on a navigation this static route cannot " &
   "perform, so the animation has no trigger here either"),
]

# ── emission ───────────────────────────────────────────────────────────────

const RegisterScope = "[data-register=\"debugger\"]"

proc buildPort(): StylPort =
  result.scope = RegisterScope
  result.bridge = initOrderedTable[string, string]()
  for (k, v) in Bridge: result.bridge[k] = v
  result.literalAliases = initOrderedTable[string, string]()
  for (k, v) in Aliases: result.literalAliases[k] = v
  result.dropRules = initOrderedTable[string, string]()
  for (k, v) in Dropped: result.dropRules[k] = v
  result.assetUrls = ctIconUrls()

proc runPort(): tuple[css: string, report: StylReport] =
  var rep = StylReport()
  let raw = transpile(vendoredSources(), buildPort(), rep)
  (scoped(raw, RegisterScope), rep)

const PortResult = runPort()

const codetracerComponentCss* = PortResult.css
  ## CodeTracer's component rules, compiled and scoped to the debugger
  ## register. Concatenated into `debugRouteCss` by `debugger_css.nim`.

proc ctPortReport*(): StylReport = PortResult.report
  ## What the port did — rule and declaration counts, every dropped rule and
  ## every declaration whose identifier did not resolve. Read by
  ## `client/tests/test_ct_components_css.nim`.

# ── the active tab, without JavaScript ─────────────────────────────────────
#
# GoldenLayout puts `.lm_active` on a tab from script. A static page cannot,
# and the one thing that must NOT happen in response is somebody re-typing
# `.lm_active`'s declarations under a `:target` selector — that is the exact
# divergence this whole module exists to prevent, and it would be invisible the
# moment upstream tuned a connector radius.
#
# So the declarations are not re-typed: every emitted rule whose selector names
# `.lm_active` is re-emitted VERBATIM under selectors that mean the same thing
# on a `:target`-driven page. Two substitutions per copy, both textual:
#
#   * `.lm_active` becomes a positional tab selector — `.lm_tab:nth-child(K)`,
#     or `.lm_tab:first-child` for the no-fragment default. A compound, so it
#     composes with every shape upstream writes: `.lm_tab.lm_active:last-child`
#     comes out as `.lm_tab.lm_tab:nth-child(K):last-child`, which is a
#     duplicate class and perfectly legal.
#
#   * the stack gains the condition that makes that tab the active one. If the
#     selector already starts at `.lm_stack` the condition is appended to it;
#     otherwise `.lm_stack<condition> ` is prepended as an ancestor.
#
# The correspondence between tab K and panel K is positional because the
# markup makes it so: `renderStack` emits the tabs and the panels from one loop
# over `node.children`, in the same order.

const MaxStackTabs* = 4
  ## How many tabs one region may hold. Four rather than the two this site
  ## places, so adding a third pane to a stack is a layout change and not a
  ## stylesheet change; `debugger_css.nim`'s panel-visibility rules are
  ## generated to the same bound.

proc activationConditions(): seq[tuple[cond, tab: string]] =
  ## The no-fragment default first, then one per tab position.
  result.add (":not(:has(> .lm_items > .lm_content:target))",
              ".lm_tab.btdefault")
  for k in 1 .. MaxStackTabs:
    result.add (":has(> .lm_items > .lm_content:nth-child(" & $k & "):target)",
                ".lm_tab:nth-child(" & $k & ")")

proc withStackCondition(sel, cond: string): string =
  ## Put `cond` on the stack this selector is about.
  let head = RegisterScope & " "
  if not sel.startsWith(head): return ""
  let rest = sel[head.len .. ^1]
  if rest.startsWith(".lm_stack"):
    head & ".lm_stack" & cond & rest[".lm_stack".len .. ^1]
  else:
    head & ".lm_stack" & cond & " " & rest

proc activeTabCss*(): string =
  ## Upstream's own active-tab rules, under the selectors a JS-free page needs.
  for line in codetracerComponentCss.splitLines:
    if ".lm_active" notin line: continue
    let brace = line.find('{')
    if brace < 0: continue
    let decls = line[brace .. ^1]
    for (cond, tab) in activationConditions():
      var sels: seq[string]
      for sel in line[0 ..< brace].split(','):
        let withCond = withStackCondition(sel.strip, cond)
        if withCond.len > 0:
          sels.add withCond.replace(".lm_active", tab)
      if sels.len > 0:
        result.add sels.join(",") & decls & "\n"

proc ctPortSummary*(): string =
  ## One-screen provenance, for a build log or a PR body.
  let r = ctPortReport()
  result.add "CodeTracer component port: " & $r.rules & " rules, " &
    $r.declarations & " declarations, from " & $vendoredSources().len &
    " vendored stylesheets\n"
  result.add "dropped rules (" & $r.dropped.len & "):\n"
  for d in r.dropped: result.add "  " & d & "\n"
  result.add "unresolved declarations (" & $r.unresolved.len & "):\n"
  for u in r.unresolved: result.add "  " & u & "\n"
