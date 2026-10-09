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
##      Every one of them is for markup or motion that cannot exist on a route
##      with no JavaScript. The count is NOT stated here: a number in prose is
##      a thing somebody updates rather than a claim somebody checks, and
##      `client/tests/test_ct_components_css.nim` asserts the relationship
##      instead — every row the port reports is either one of these keys or a
##      build-condition arm that names its own condition, and every key here is
##      used by at least one row.
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
## Stylus emits an identifier it cannot resolve verbatim and the browser then
## discards the whole declaration. The port reproduces that — the declaration
## is dropped and recorded in `ctPortReport().unresolved` — and the record is
## only worth having while the list is the SHORT one, because every row on it
## is a declaration that is styling nothing.
##
## TWO FAMILIES are legitimate, and nothing else is:
##
##   * `ct-images-*`, CodeTracer's own SVG asset handles, which this site does
##     not ship. (The nine icons it DOES ship are the table above; these are
##     the rest, and they are not vendored.)
##
##   * the theme-file constants — `LAYOUT_*`, `RR_TICKS_*`,
##     `TOOLTIP_DELAY_TIMER`, `SEARCHED_TOKEN_COLOR`. Every one of them is
##     assigned in `src/frontend/styles/defaults.styl` or in a
##     `default_*_theme.styl` beside it, and this port vendors neither: it
##     carries `styles/components/`, which is the layer that DRAWS, and a
##     theme file is the layer that is replaced wholesale per theme. All but
##     one of the values behind them are a raw hex or a CodeTracer SVG url
##     (`TOOLTIP_DELAY_TIMER` is the one that is not — it is a duration), so
##     importing them would be importing exactly what the bridge exists to
##     keep out.
##
## A CodeTracer ROLE NAME — anything `colors-*` — is NOT in either family.
## Upstream's generated token layer resolves all of them at the pinned commit,
## so an unresolved one means a missing row in `Bridge`, which is a declaration
## of upstream's that this port silently stopped emitting.
## `client/tests/test_ct_components_css.nim` asserts exactly that, which is how
## a missing row shows up as a test failure rather than as a quietly unstyled
## panel. (Four of them were missing and had been for two re-vendors: a tab's
## hover underline, a toolbar divider, and the dropdown menu's own surface and
## ink. The rows are in `Bridge` above, each with what it resolves to upstream
## and what it was costing.)

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
# published: 9 of the 13 `url()`s in the built stylesheet asked for a path this
# site does not serve, and all 9 sat inside the `[data-register="debugger"]`
# scope.
#
# AND NOT ONE OF THEM WAS A 404 FOR A VISITOR, WHICH IS A CORRECTION OF WHAT
# THIS COMMENT USED TO SAY. A browser fetches a `mask-image` only for an
# element the rule MATCHES, and `ct_css_reach.txt` is the measurement: all nine
# of these urls sit on `.ct-origin-icon-*`, `.ct-origin-badge-icon`,
# `.value-history-button::before` and `.custom-noir-icon::before`, and ZERO of
# those selectors is emitted anywhere — over 349 exported pages and all three
# JS bundles, raw and char-code-decoded. The urls were broken AND unreached,
# which is two defects and not one, and fixing the first while reporting the
# pair as fixed is what the register exists to stop. The rules are correct now
# and still reach nothing; `INERT class ct-origin-*` says precisely what would
# have to exist, and `client/src/assets/ct-icons/README.md` says why the bytes
# are kept rather than deleted.
#
# The sheets are NOT edited to fix that. They are vendored byte-verbatim and
# `ci/test/ct-styles-vendor.sh` hashes them against the pinned commit, so a hand
# edit would fail that gate by construction and be reverted by the next
# re-vendor besides. Where a file is PUBLISHED is a BlockTracer build decision,
# and a build decision belongs in the port: `ct_styl.rewriteUrls` consumes the
# table below and RAISES on any relative url it does not find there.
#
# The icons themselves are vendored under `client/src/assets/ct-icons/`, from
# the same CodeTracer commit as the sheets; see that directory's README, which
# carries the reachability finding as well as the provenance.

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
  # neutral-800: the OTHER half of upstream's `surface-input-*` pair, and it
  # has no BlockTracer rung — this site's form controls sit on ONE surface
  # (`.nav input`, `.search input` in `components/styles.nim`) and that surface
  # is `sunken`. So the family binds as a family: both of CodeTracer's input
  # surfaces land on the one BlockTracer input surface, which is the same
  # decision the row above already makes for `-secondary` and makes the pair
  # read as one choice rather than two. The gap is one rung (800 -> 700).
  #
  # Its only appearance in the vendored set is `shared_widgets.styl:722`,
  # `.dropdown-list { color: … }` — a SURFACE token used as an ink colour,
  # which is upstream's own oddity and is reproduced rather than corrected: it
  # is overridden on every item by `.dropdown-list-item`'s
  # `color: colors-ui-text-primary-body`, so it styles nothing a reader sees,
  # and a port that "fixed" a declaration would be the divergence this module
  # exists to end.
  ("colors-ui-surface-input-default", "var(--bt-surface-sunken)"),        # role: neutral-800 -> neutral-700
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
  # neutral-950, and the name is the whole argument. In CodeTracer's `base`
  # group `raised` is the DARKEST of the three (canvas 900, panel 700, raised
  # 950): a thing drawn OVER the canvas separates from it by going a rung
  # darker. BlockTracer has exactly one surface whose job is that — `overlay`,
  # the rung `--bt-elevation-overlay`'s shadow is paired with — and in
  # BlockTracer the separation runs the other way, one rung LIGHTER than
  # `raised` (850 against 900), because this register's canvas is black and
  # darker is not available. So the ramp positions disagree and the RELATION
  # survives: a floating menu is one clearly-separated rung off the panel it
  # hangs from, in the direction each product's canvas allows.
  #
  # The only vendored use is `shared_widgets.styl:721`, `.dropdown-list`'s own
  # background, which is precisely a floating menu. It was being DROPPED, so
  # that menu had no surface of its own at all and showed whatever was behind
  # it.
  ("colors-ui-surface-base-raised", "var(--bt-surface-overlay)"),         # role: neutral-950 -> neutral-850
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
  # `generated/mapped.styl:92` resolves `divider-primary` to
  # neutral-cold-600 — the SAME primitive as `border-secondary` on the line
  # above (`mapped.styl:74`). Two role names over one value, so one binding:
  # anything else would make the port draw a divider and a secondary border in
  # two different colours where upstream draws them in one. The only vendored
  # use is `shared_widgets.styl:419`, `.separate-bar`'s `border-left` — the
  # hairline that separates toolbar groups — and it was being DROPPED, so that
  # bar was a zero-width element with no visible rule at all.
  ("colors-ui-divider-primary", "var(--bt-border-subtle)"),               # role: neutral-600 -> neutral-700 (= border-secondary)
  # `colors-base-white`, `mapped.styl:56` — not a ramp position at all but the
  # ramp's END, i.e. "as far from the panel as this product can get". Bound by
  # ROLE to the strongest ink this register has, NOT to a white of our own: a
  # literal `#ffffff` is correct in CodeTracer, which ships one dark theme, and
  # invisible in BlockTracer's light one, where the tab sits on a near-white
  # surface. `--bt-text-strong` is neutral-50 in dark and neutral-1000 in
  # light, so "the hover underline jumps to maximum contrast" stays true in
  # both — which is the reason this table binds roles and not hexes, stated in
  # its own header.
  #
  # The one vendored use is `tab.styl:38`, the hover arm's
  # `border-bottom-color`. It was being DROPPED, so hovering a tab moved its
  # background but left the 0.125em underline at `border-primary` — the hover
  # had half its two channels.
  ("colors-ui-border-contrast", "var(--bt-text-strong)"),                 # role: base-white -> neutral-50 (dark) / neutral-1000 (light)
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
   "applied — and it carries the ONE raw hex colour upstream writes in the " &
   "vendored set, which `test_static_export`'s shipped-rules scan rejects (and " &
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

# ── 4. the reachability register ────────────────────────────────────────────
#
# `Dropped` above says which rules leave the port. THE CONVERSE HAD NO CHECK:
# nothing asserted that a rule which was NOT dropped can match anything, and
# three defects came out of that gap — `.component-container` served while
# nothing wore it, nine icons whose urls were fixed while none of their
# selectors is emitted anywhere, and `.separate-bar` / `.dropdown-list` given
# colour bindings while matching zero elements. Two of the three were reported
# as fixed.
#
# `ct_css_reach.txt` is that converse, as data. Its own header is the argument
# for every decision in it — including why it is a text file rather than a
# `seq` here, which is that TWO checks in two languages read the same rows and
# a second copy of the register would be the divergence this module exists to
# prevent. `staticRead` for the reason the vendored sheets use it: the bytes
# become part of the compiled artefact, so the suite reads what shipped.

const ReachRegisterText = staticRead("ct_css_reach.txt")

type
  PortItemKind* = enum
    ## What a selector names. Pseudo-classes, pseudo-elements and every
    ## attribute selector other than `[class*=…]` are NOT item kinds; the
    ## register's header says why for each, and `[data-register="debugger"]`
    ## falls out by the same rule.
    pikClass        ## `.foo`
    pikClassPart    ## the substring of a `[class*="foo"]`
    pikId           ## `#foo`
    pikElement      ## a bare tag name, in a selector naming no class/id/part

  PortItem* = object
    kind*: PortItemKind
    name*: string
    sample*: string
      ## One selector it came from, so a failure names the rule rather than
      ## only the class.

  ReachVerdict* = enum
    rvLive          ## the markup emits it, and the Node half proves that
    rvInert         ## emitted knowing nothing matches it

  ReachRow* = object
    verdict*: ReachVerdict
    kind*: PortItemKind
    pattern*: string      ## may contain `*`
    evidence*: string     ## "" (markup) or "bundle", for a LIVE row
    reason*: string
    line*: int            ## 1-based, for a failure message

proc itemKindOf(s: string): PortItemKind =
  case s
  of "class": pikClass
  of "classpart": pikClassPart
  of "id": pikId
  of "element": pikElement
  else: raise newException(ValueError, "unknown register kind: " & s)

proc parseReachRegister*(text: string): seq[ReachRow] =
  ## The register, as rows. A `LIVE`/`INERT` line opens a row and every
  ## following indented line is its reason; a blank line or a comment inside
  ## the indented block is skipped rather than ending it, so the reasons can be
  ## written as prose.
  var lineNo = 0
  var runStart = -1
    ## The first row of the consecutive run a reason block will attach to.
  var reasonSeen = false
  for raw in text.splitLines:
    inc lineNo
    if raw.len == 0: continue
    if raw.startsWith("#"): continue
    if raw[0] in {' ', '\t'}:
      # A continuation of the reason — and it applies to EVERY row of the
      # consecutive run above it, not only to the last. Upstream's vocabulary
      # comes in families whose reason is one sentence for all of them
      # (`lm_header` / `lm_tabs` / `lm_tab` / `lm_title` are one tab strip),
      # and attaching the prose only to the last row left the others with an
      # empty reason — which the suite's own minimum-length check caught.
      if runStart >= 0:
        let piece = raw.strip
        if piece.len > 0 and not piece.startsWith("#"):
          for i in runStart .. result.high:
            if result[i].reason.len > 0: result[i].reason.add " "
            result[i].reason.add piece
          reasonSeen = true
      continue
    let parts = raw.splitWhitespace
    if parts.len < 3:
      raise newException(ValueError,
        "ct_css_reach.txt:" & $lineNo & ": a row needs VERDICT KIND PATTERN")
    var row = ReachRow(kind: itemKindOf(parts[1]), pattern: parts[2],
                       line: lineNo)
    case parts[0]
    of "LIVE": row.verdict = rvLive
    of "INERT": row.verdict = rvInert
    else:
      raise newException(ValueError,
        "ct_css_reach.txt:" & $lineNo & ": verdict is LIVE or INERT, not " &
        parts[0])
    if parts.len > 3: row.evidence = parts[3]
    if runStart < 0 or reasonSeen:
      runStart = result.len
      reasonSeen = false
    result.add row

proc reachRegister*(): seq[ReachRow] = parseReachRegister(ReachRegisterText)
  ## The register the gate's two halves share.
  ## `tools/ci/check-css-reachable.mjs` parses the same bytes.

proc matchesPattern*(pattern, name: string): bool =
  ## `*` is the only metacharacter, and it may appear anywhere.
  if '*' notin pattern: return pattern == name
  let segs = pattern.split('*')
  var pos = 0
  for i, seg in segs:
    if seg.len == 0: continue
    if i == 0:
      if not name.startsWith(seg): return false
      pos = seg.len
    elif i == segs.high:
      if not name.endsWith(seg): return false
      if name.len - seg.len < pos: return false
    else:
      let hit = name.find(seg, pos)
      if hit < 0: return false
      pos = hit + seg.len
  true

# ── the inventory: what the port's selectors actually name ──────────────────

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}

proc scanSelector*(sel: string; items: var seq[PortItem]) =
  ## One selector, into items. The two rules that are not obvious, and both
  ## are in the register's header:
  ##
  ##   * a class inside `:not(…)` is NOT an item — the rule matches when it is
  ##     absent — while `:has(…)`, `:is(…)` and `:where(…)` ARE descended into,
  ##     for the opposite reason;
  ##   * an attribute selector contributes only when it is `[class*="…"]` and
  ##     its siblings; every other attribute is state or out of scope.
  var i = 0
  var found = 0
  template addItem(k: PortItemKind; n: string) =
    items.add PortItem(kind: k, name: n, sample: sel)
    inc found
  while i < sel.len:
    case sel[i]
    of '.', '#':
      let kind = if sel[i] == '.': pikClass else: pikId
      var j = i + 1
      while j < sel.len and isIdentChar(sel[j]): inc j
      if j > i + 1: addItem(kind, sel[i + 1 ..< j])
      i = j
    of '[':
      let close = sel.find(']', i)
      if close < 0: break
      let body = sel[i + 1 ..< close]
      let eq = body.find('=')
      if eq > 0:
        let lhs = body[0 ..< eq].strip(chars = {' ', '*', '^', '$', '|', '~'})
        if lhs == "class":
          let v = body[eq + 1 .. ^1].strip(chars = {' ', '"', '\''})
          if v.len > 0: addItem(pikClassPart, v)
      i = close + 1
    of ':':
      var j = i
      while j < sel.len and sel[j] == ':': inc j
      let nameStart = j
      while j < sel.len and isIdentChar(sel[j]): inc j
      let pseudo = sel[nameStart ..< j]
      if j < sel.len and sel[j] == '(':
        # the matching close paren, counting nesting
        var depth = 0
        var k = j
        while k < sel.len:
          if sel[k] == '(': inc depth
          elif sel[k] == ')':
            dec depth
            if depth == 0: break
          inc k
        let inner = sel[j + 1 ..< min(k, sel.len)]
        if pseudo in ["has", "is", "where"]:
          var innerItems: seq[PortItem]
          scanSelector(inner, innerItems)
          for it in innerItems:
            items.add PortItem(kind: it.kind, name: it.name, sample: sel)
            inc found
        i = k + 1
      else:
        i = j
    else:
      inc i
  if found == 0:
    # Element selectors are only an item for a selector that names nothing
    # else, which is what makes the inventory small: `.lm_tab span` asks
    # nothing of `span` that `.lm_tab` does not already ask.
    #
    # Stripped in two passes before the tags are read, and both are the
    # difference between an inventory and a word list: an attribute selector
    # carries identifiers that are not elements (`data-register`, `debugger`)
    # and so does every pseudo (`hover`, `focus-visible`,
    # `-webkit-scrollbar-thumb`). The first version of this read all three as
    # tag names and produced twenty-two items that are not elements at all.
    var bare = ""
    var k = 0
    while k < sel.len:
      if sel[k] == '[':
        let close = sel.find(']', k)
        if close < 0: break
        k = close + 1
      elif sel[k] == ':':
        inc k
        while k < sel.len and sel[k] == ':': inc k
        while k < sel.len and (isIdentChar(sel[k]) or sel[k] == '-'): inc k
        if k < sel.len and sel[k] == '(':
          var depth = 0
          while k < sel.len:
            if sel[k] == '(': inc depth
            elif sel[k] == ')':
              dec depth
              if depth == 0:
                inc k
                break
            inc k
        bare.add ' '
      else:
        bare.add sel[k]
        inc k
    for tok in bare.multiReplace(("*", " "), (">", " "), ("+", " "),
                                 ("~", " ")).splitWhitespace:
      var ok = tok.len > 0
      for c in tok:
        if c notin {'a'..'z', '0'..'9'}: ok = false
      if ok and tok[0] in {'a'..'z'}:
        items.add PortItem(kind: pikElement, name: tok, sample: sel)

proc ctPortItems*(): seq[PortItem] =
  ## Every class, `[class*=]` substring, id and element the port's selectors
  ## name, deduplicated by (kind, name) and keeping the first sample.
  ##
  ## Over `codetracerComponentCss` AND `activeTabCss()`, because both are what
  ## this module emits. (The second adds nothing today — it is a textual
  ## substitution of `.lm_active` for selectors built from `.lm_tab`,
  ## `.lm_stack`, `.lm_items`, `.lm_content` and `.btdefault`, all of which the
  ## first already names — and asserting that is cheaper than asserting a
  ## reader will remember it.)
  var seen = initTable[string, bool]()
  for css in [codetracerComponentCss, activeTabCss()]:
    for line in css.splitLines:
      if line.len == 0 or line.startsWith("/*"): continue
      let brace = line.find('{')
      if brace <= 0: continue
      for sel in line[0 ..< brace].split(','):
        var items: seq[PortItem]
        scanSelector(sel.strip, items)
        for it in items:
          let key = $it.kind & "\u0000" & it.name
          if key notin seen:
            seen[key] = true
            result.add it

proc reachRowsFor*(rows: seq[ReachRow]; it: PortItem): seq[int] =
  ## Which rows cover this item. Exactly one is the requirement, so the
  ## failure message can say "none" or name the several.
  for i, r in rows:
    if r.kind == it.kind and matchesPattern(r.pattern, it.name): result.add i
