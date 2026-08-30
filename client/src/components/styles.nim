## Explorer CSS for the BlockTracer IsoNim client — Layer 2 (VD.2 Foundations).
##
## Two parts, both inlined into every page's <head> by components/layout.nim:
##
##   * `fontFaceCss` — @font-face for the brand faces vendored from
##     codetracer-design-system (Space Grotesk sans + Space Mono) under
##     src/assets/fonts/, served from /assets/fonts/.
##
##   * `globalCss` — the shell and view rules.
##
## ── The rule this file exists to obey ──────────────────────────────────────
##
## Every colour, size, space, radius, duration and measure below is
## `var(--bt-*)`: a SEMANTIC token from the web lineage
## (design_system/web.tokens.json, emitted by design_system/tokens.nim). There
## are no raw hex values, no raw design pixels, and no brand primitives — a
## rule like `color: var(--bt-color-indigo-400)` does not exist to be written,
## because the primitive ramp is no longer emitted at all. That is
## `verify_no_raw_values_in_views`, checked by tools/design/check-tokens.mjs.
##
## Four kinds of literal survive on purpose, because none of them is a design
## decision and none of them can be a custom property:
##
##   1. `0`, `100%`, `1fr`, `auto`, `min(...)` and other structural values.
##   2. Media-query breakpoints — CSS cannot read a custom property in a
##      media condition, so a breakpoint is written where it is used.
##   3. `border-collapse`, `overflow`, `position` and the rest of layout.
##   4. `1px` where it is a hairline: it comes from `--bt-stroke-hairline`.
##
## Each is enumerated in the checker's allowlist WITH a reason, and the
## checker fails if an allowlist entry stops matching anything — so the
## allowlist cannot rot into a blanket exemption.
##
## ── How the findings below are cited ───────────────────────────────────────
##
## VD.2's review round REPLACED VD.1's and reused the finding ids, so the bare
## `L1/1` / `L2/6` / `L2/7` this file used to carry still parsed and pointed at
## different findings — and `L1/13` named nothing at all. Two forms are used
## now, and check B4 of tools/design/check-tokens.mjs fails on either if it
## stops resolving:
##
##   * `ledger@<revision>:<id>` — a finding in the CURRENT reviews/ledger.json.
##     The revision is part of the citation, so a round that replaces its
##     predecessor turns every stale citation red in one run.
##   * a FILE PATH — evidence that outlived the round that produced it.
##
## ── What VD.2 changed and why ──────────────────────────────────────────────
##
##  * **The primary button.** `.btn` now sets `background` unconditionally.
##    Previously it did not, so `<button class="btn ghost">` inherited the user
##    agent's `ButtonFace` (#efefef) while its `<a class="btn primary">`
##    siblings — being anchors — did not. Measured 1.04:1, in BOTH colour
##    schemes. VD.1's ledger is superseded, but the measurement survives
##    verbatim in the control round of reviews/break-round-debug-affordance.json,
##    where ADV and L2 independently report the primary action as a near-white
##    label on a near-white fill against the UNBROKEN capture.
##  * **One rhythm.** Stack, group and section gaps are distinct
##    `--bt-rhythm-*` roles, each at least 1.75x the one below, so proximity
##    groups; the row rung is the register's own `--bt-density-cell-y`.
##    Previously a section boundary and a table row pitch were both 49px
##    (VD.1 round 1; recorded in docs/DESIGN-DIVERGENCES-WEB.md §3.2).
##  * **One grid.** The nav uses the same `.inner` container as the body, so
##    the brand and the search field align to the page beneath them (VD.1
##    round 1; the measurement is recorded in docs/DESIGN-DIVERGENCES-WEB.md
##    row D-07).
##  * **A section-heading level.** `.sec-title` is a real 20px heading between
##    the 32px page title and 16px body; the mono uppercase kicker is a kicker
##    again, never the heading itself (VD.1 round 1; the remaining VD.2
##    findings on the heading scale are
##    ledger@2026-08-29.2:tx-detail/wide/light/L1/8 and
##    ledger@2026-08-29.2:tx-detail/wide/light/L1/10).
##  * **Mono means machine value.** Breadcrumbs, placeholders and grid labels
##    are the sans face; mono is reserved for hashes, addresses, selectors,
##    amounts and code, so it marks "copyable identifier" again, and every
##    numeric column carries tabular figures
##    (ledger@2026-08-29.2:tx-detail/wide/light/L1/6).
##  * **A measure.** Running prose is capped at `--bt-measure-prose` instead of
##    the full 1140px container (VD.1 round 1; recorded as divergence row D-06).
##  * **Focus, hover and active** are one treatment, defined once, shared by
##    both registers (Design-System.md §2).

const fontFaceCss* = """
@font-face{font-family:'Space Grotesk Variable';font-weight:400;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceGrotesk-Regular.woff2) format('woff2');}
@font-face{font-family:'Space Grotesk Variable';font-weight:500;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceGrotesk-Medium.woff2) format('woff2');}
@font-face{font-family:'Space Grotesk Variable';font-weight:700;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceGrotesk-Bold.woff2) format('woff2');}
@font-face{font-family:'Space Mono';font-weight:400;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceMono-Regular.ttf) format('truetype');}
"""

const globalCss* = """
/* ── reset ──────────────────────────────────────────────────────────────── */
*{margin:0;padding:0;box-sizing:border-box}
html{scroll-behavior:smooth}
html,body{background:var(--bt-surface-canvas);color:var(--bt-text-default);font-family:var(--bt-font-sans),var(--bt-font-sans-fallback);font-size:var(--bt-density-body-size);line-height:var(--bt-density-line)}
body{overflow-x:hidden}
/* The user agent gives <button> and <input> their own font and a ButtonFace
   background. Both are inherited here rather than left to the UA, which is
   the class of defect that made the primary action 1.04:1. */
button,input,select,textarea{font:inherit;color:inherit;background:none;border:0}
button{cursor:pointer}
img,svg{max-width:100%;display:block}
::selection{background:var(--bt-surface-selected);color:var(--bt-text-strong)}
a{color:inherit;text-decoration:none}

/* ── focus, hover, active: one treatment, both registers ────────────────── */
:where(a,button,input,select,textarea,summary,[tabindex]):focus-visible{
  outline:var(--bt-focus-width) solid var(--bt-focus-ring);
  outline-offset:var(--bt-focus-offset)}
@media (prefers-reduced-motion:reduce){*{transition:none!important;animation:none!important;scroll-behavior:auto}}

/* ── type scale ─────────────────────────────────────────────────────────── */
.display{font-size:var(--bt-type-display-size);font-weight:var(--bt-type-display-weight);line-height:var(--bt-type-display-line);letter-spacing:var(--bt-type-display-tracking);color:var(--bt-text-strong);max-width:var(--bt-measure-title)}
.h1{font-size:var(--bt-type-h1-size);font-weight:var(--bt-type-h1-weight);line-height:var(--bt-type-h1-line);letter-spacing:var(--bt-type-h1-tracking);color:var(--bt-text-strong);max-width:var(--bt-measure-title)}
.h1.identifier{font-size:var(--bt-type-h1-size);line-height:var(--bt-type-h1-line);letter-spacing:var(--bt-type-h1-tracking);color:var(--bt-text-strong);max-width:none;word-break:normal}
.h2{font-size:var(--bt-type-h2-size);font-weight:var(--bt-type-h2-weight);line-height:var(--bt-type-h2-line);letter-spacing:var(--bt-type-h2-tracking);color:var(--bt-text-strong)}
.sec-title{font-size:var(--bt-type-h2-size);font-weight:var(--bt-type-h2-weight);line-height:var(--bt-type-h2-line);letter-spacing:var(--bt-type-h2-tracking);color:var(--bt-text-strong);margin-bottom:var(--bt-space-xs)}
.sec-title.next{margin-top:var(--bt-rhythm-section);border-top:var(--bt-stroke-hairline) solid var(--bt-border-default);padding-top:var(--bt-rhythm-stack)}
.sec-title.sibling{margin-top:var(--bt-rhythm-group);border-top:0;padding-top:0}
.lead{font-size:var(--bt-type-body-size);line-height:var(--bt-type-body-line);color:var(--bt-text-muted);max-width:var(--bt-measure-prose);margin-top:var(--bt-rhythm-stack)}
.muted{color:var(--bt-text-muted)}
.subtle{color:var(--bt-text-subtle)}
.accent{color:var(--bt-accent-default)}
.eyebrow{font-size:var(--bt-type-eyebrow-size);font-weight:var(--bt-type-eyebrow-weight);line-height:var(--bt-type-eyebrow-line);letter-spacing:var(--bt-type-eyebrow-tracking);text-transform:uppercase;color:var(--bt-text-subtle);display:flex;align-items:center;gap:var(--bt-space-sm);margin-bottom:var(--bt-space-sm)}
.eyebrow::before{content:'';width:var(--bt-space-lg);height:var(--bt-stroke-hairline);background:var(--bt-border-strong)}

/* ── machine values: the product's actual surface area ──────────────────── */
/* Mono marks a copyable machine value and nothing else. */
code,.mono,.identifier{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);font-size:var(--bt-type-identifier-size);line-height:var(--bt-type-identifier-line);letter-spacing:var(--bt-type-identifier-tracking);font-variant-numeric:var(--bt-numeric-features)}
.identifier{color:var(--bt-text-code);word-break:break-all;display:inline-block}
.identifier.lead{font-size:var(--bt-type-identifier-lead-size);font-weight:var(--bt-type-identifier-lead-weight);line-height:var(--bt-type-identifier-lead-line);letter-spacing:var(--bt-type-identifier-lead-tracking);color:var(--bt-text-strong)}
/* Every digit that sits in a column is tabular, so heights and amounts do not
   ripple against each other (rubric A5). `.tnum` is tabular figures ALONE, for
   digits inside a heading or a sentence where the face must not change; `.num`
   and `.numeric` are the full numeric treatment for data. */
.tnum,.num,.numeric,td.num,.stat .v{font-variant-numeric:var(--bt-numeric-features)}
.num,.numeric,td.num{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);font-size:var(--bt-type-numeric-size);line-height:var(--bt-type-numeric-line)}

/* ── the explorer shell: the footer ENDS the page ───────────────────────── */
/* `pageLayout` renders nav + `main.pagebody` + `footer.foot` as three
   in-flow blocks, so on a page shorter than the viewport the footer stopped
   wherever the content did and the canvas continued below it. Measured at
   1440x1000 on `/{chain}/address/{addr}/code` for an account with no code
   binding: the strip ran 571..767 with 233px of empty canvas under it, so the
   raised surface that closes the page read as a band floating in the middle of
   one. Eleven of the published routes are shorter than a 1200px viewport.
   It is not a footer treatment — the strip is correct — it is that nothing
   made the body fill the viewport.

   `height:100%` down the chain rather than a viewport unit, for the reason
   `debugger_css.nim` gives at its own shell: `vh` is a raw length and the
   chain says the same thing.

   The scope is `:has(.foot)` and NOT the register attribute, for two reasons
   and neither is style. It is the precondition itself — "make the body fill
   the viewport so the footer is pushed to the bottom of it" is a statement
   about a page that HAS a footer, and `debugLayout` renders none, so the
   debugger's shell (already `height:100%;overflow:hidden`) cannot acquire a
   second, contradictory one however the registers are later rearranged. And
   this stylesheet is INLINED into every page, so a selector keyed on the
   explorer register would carry that attribute's own text into the bytes of
   the DEBUG page, where `test_debug_route` reads the served document to prove
   the explorer register is gone — the same "naming it puts it back in the
   served bytes" trap `debugger_css.nim` calls out at its narrow rules, which
   is why this paragraph does not spell the attribute out either.

   `.nav` is `position:fixed`, so making the body a flex column moves nothing
   that was in flow except the two blocks this rule is about. */
html:has(.foot){height:100%}
body:has(> .foot){min-height:100%;display:flex;flex-direction:column}

/* ── layout primitives: ONE grid for the header and the body ────────────── */
.inner{max-width:var(--bt-layout-container);margin:0 auto;padding:0 var(--bt-layout-gutter);width:100%}
.sec{padding:var(--bt-rhythm-group) 0;position:relative}
/* `flex:1 0 auto` and not `1 1 auto`: the body takes the slack a short page
   leaves, and never gives up height on a long one. */
.pagebody{flex:1 0 auto;padding-top:calc(var(--bt-layout-nav-height) + var(--bt-rhythm-group))}
.stack{margin-top:var(--bt-rhythm-stack)}
.tight{margin-top:var(--bt-space-sm)}
.group{margin-top:var(--bt-rhythm-group)}
.titlerow{display:flex;gap:var(--bt-space-sm);align-items:center;flex-wrap:wrap}
.badgerow{display:inline-flex;gap:var(--bt-space-xs);align-items:center;flex-wrap:wrap}

/* ── nav ────────────────────────────────────────────────────────────────── */
.nav{position:fixed;top:0;left:0;right:0;z-index:20;height:var(--bt-layout-nav-height);display:flex;align-items:center;border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);background:var(--bt-surface-raised)}
.nav .inner{display:flex;justify-content:space-between;align-items:center;gap:var(--bt-space-lg)}
.brand{font-size:var(--bt-type-h3-size);font-weight:var(--bt-type-h1-weight);letter-spacing:var(--bt-type-h2-tracking);color:var(--bt-text-strong);display:flex;align-items:center;gap:var(--bt-space-xs);flex:0 0 auto}
.brand .sq{width:var(--bt-space-md);height:var(--bt-space-md);border:var(--bt-stroke-thick) solid var(--bt-accent-default);border-radius:var(--bt-radius-xs);position:relative;flex:0 0 auto}
.brand .sq::after{content:'';position:absolute;inset:var(--bt-space-3xs);background:var(--bt-accent-default);border-radius:var(--bt-radius-xs)}
.nav .links{display:flex;gap:var(--bt-space-lg);align-items:center;font-size:var(--bt-type-body-sm-size);flex:1 1 auto;justify-content:flex-end}
.nav .links a.opt{color:var(--bt-text-muted);transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.nav .links a.opt:hover{color:var(--bt-text-strong)}
.nav form{flex:0 1 var(--bt-layout-search);min-width:0}
.nav input{width:100%;background:var(--bt-surface-sunken);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-md);color:var(--bt-text-default);font-size:var(--bt-type-body-sm-size);padding:var(--bt-space-xs) var(--bt-space-sm);transition:border-color var(--bt-motion-fast) var(--bt-motion-ease)}
.nav input::placeholder{color:var(--bt-text-subtle)}
.nav input:hover{border-color:var(--bt-border-strong)}

/* ── breadcrumbs (sans: navigation is prose, not a machine value) ───────── */
.crumbs{font-size:var(--bt-type-caption-size);line-height:var(--bt-type-caption-line);color:var(--bt-text-subtle);display:flex;gap:var(--bt-space-xs);flex-wrap:wrap;margin-bottom:var(--bt-rhythm-stack)}
.crumbs a{color:var(--bt-text-link);text-decoration:underline;text-underline-offset:var(--bt-space-3xs);transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.crumbs a:hover{color:var(--bt-text-link)}
.crumbs .sep{color:var(--bt-text-subtle)}

/* ── hero ───────────────────────────────────────────────────────────────── */
.hero{padding:var(--bt-rhythm-section) 0}
.search{margin-top:var(--bt-rhythm-stack);display:flex;gap:var(--bt-space-sm);max-width:var(--bt-measure-prose)}
.search input{flex:1 1 auto;min-width:0;background:var(--bt-surface-raised);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-md);color:var(--bt-text-default);font-size:var(--bt-type-body-size);padding:var(--bt-density-control-y) var(--bt-density-control-x);transition:border-color var(--bt-motion-fast) var(--bt-motion-ease)}
.search input::placeholder{color:var(--bt-text-subtle)}
.search input:hover{border-color:var(--bt-border-strong)}
.chainstrip{display:flex;gap:var(--bt-space-md);flex-wrap:wrap;margin-top:var(--bt-rhythm-group)}
.chaincard{display:block;border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);padding:var(--bt-space-lg) var(--bt-space-xl);background:var(--bt-surface-raised);box-shadow:var(--bt-elevation-raised);transition:border-color var(--bt-motion-fast) var(--bt-motion-ease),background var(--bt-motion-fast) var(--bt-motion-ease)}
.chaincard:hover{border-color:var(--bt-border-accent);background:var(--bt-surface-hover)}
.chaincard:active{background:var(--bt-surface-selected)}
.chaincard .name{font-size:var(--bt-type-h3-size);font-weight:var(--bt-type-h3-weight);color:var(--bt-text-strong)}
.chaincard .meta{color:var(--bt-text-muted);font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);font-size:var(--bt-type-caption-size);font-variant-numeric:var(--bt-numeric-features);margin-top:var(--bt-space-2xs)}

/* ── headline stat row ──────────────────────────────────────────────────── */
.stats{display:flex;gap:var(--bt-rhythm-group);flex-wrap:wrap;margin-top:var(--bt-rhythm-stack)}
.stat .k{font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);line-height:var(--bt-type-label-line);letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;color:var(--bt-text-muted)}
.stat .v{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);font-size:var(--bt-type-h2-size);line-height:var(--bt-type-h2-line);color:var(--bt-text-strong);margin-top:var(--bt-space-2xs)}
.stat .v.mono{font-size:var(--bt-type-h3-size)}

/* ── definition grid (block / tx detail) ────────────────────────────────── */
.dl{display:grid;grid-template-columns:var(--bt-layout-label-column) minmax(0,1fr);gap:0;border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);overflow:hidden;background:var(--bt-surface-raised);box-shadow:var(--bt-elevation-raised)}
.dl dt{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);line-height:var(--bt-space-lg);letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;color:var(--bt-text-muted);background:var(--bt-surface-sunken);border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
/* `overflow-wrap:anywhere` and NOT `word-break:break-all`. Both stop a 66-char
   hash from blowing out the value column, and `anywhere` is the one that also
   contributes to min-content sizing, so the grid track is still sized as if
   the break were available. The difference is what they do to PROSE, and this
   list carries both: `break-all` breaks at whatever character the line ends on
   whether or not the word would have fitted, which on /settings at 375px
   produced "trace op / ens anonymously", "not yet i / mplemented", "nothing
   switc / hed on" and "any other third part / y." in one screen. `anywhere`
   breaks a word only when it cannot fit, which is the case the rule is for. */
.dl dd{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);min-width:0;overflow-wrap:anywhere;font-size:var(--bt-type-body-sm-size);line-height:var(--bt-space-lg);font-variant-numeric:var(--bt-numeric-features)}
.dl dd .identifier,.dl dd code{font-size:inherit;line-height:inherit}
.dl dt:last-of-type,.dl dd:last-of-type{border-bottom:0}
.dl dd a{color:var(--bt-text-link);text-decoration:underline;text-underline-offset:var(--bt-space-3xs);transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.dl dd a:hover{color:var(--bt-text-link-hover)}

/* ── tables ─────────────────────────────────────────────────────────────── */
.tablewrap{overflow-x:auto;border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);background:var(--bt-surface-raised);box-shadow:var(--bt-elevation-raised)}
table.tbl{width:100%;border-collapse:collapse;font-size:var(--bt-density-data-size)}
table.tbl th{text-align:left;font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);line-height:var(--bt-type-label-line);letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;color:var(--bt-text-muted);padding:var(--bt-density-cell-y) var(--bt-density-cell-x);background:var(--bt-surface-sunken);border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-default);white-space:nowrap}
table.tbl th.num{text-align:right}
table.tbl td{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);white-space:nowrap;vertical-align:middle}
table.tbl tr:last-child td{border-bottom:0}
table.tbl tbody tr{transition:background var(--bt-motion-fast) var(--bt-motion-ease)}
table.tbl tbody tr:hover{background:var(--bt-surface-hover)}
table.tbl td.hash a,table.tbl td a.addr{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);color:var(--bt-text-link);transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
table.tbl td.hash a:hover,table.tbl td a.addr:hover{color:var(--bt-text-link-hover);text-decoration:underline;text-underline-offset:var(--bt-space-3xs)}
table.tbl td.num{text-align:right}
.empty{padding:var(--bt-rhythm-group) var(--bt-density-cell-x);color:var(--bt-text-muted);text-align:center}

/* ── badges: colour never carries the meaning alone (rubric A7) ─────────── */
.badge{display:inline-flex;align-items:center;font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);line-height:var(--bt-type-label-line);letter-spacing:var(--bt-type-label-tracking);padding:var(--bt-space-3xs) var(--bt-space-xs);border-radius:var(--bt-radius-sm);border:var(--bt-stroke-hairline) solid var(--bt-status-neutral-border);background:var(--bt-status-neutral-bg);color:var(--bt-status-neutral-fg);white-space:nowrap}
.badge.ok{color:var(--bt-status-success-fg);border-color:var(--bt-status-success-border);background:var(--bt-status-success-bg)}
.badge.bad{color:var(--bt-status-danger-fg);border-color:var(--bt-status-danger-border);background:var(--bt-status-danger-bg)}
.badge.warn{color:var(--bt-status-warning-fg);border-color:var(--bt-status-warning-border);background:var(--bt-status-warning-bg)}
.badge.info{color:var(--bt-status-info-fg);border-color:var(--bt-status-info-border);background:var(--bt-status-info-bg)}
.badge.muted{color:var(--bt-status-neutral-fg);border-color:var(--bt-status-neutral-border);background:var(--bt-status-neutral-bg)}
.badge.lg{font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line);padding:var(--bt-space-2xs) var(--bt-space-sm)}
.badge.coverage{border-radius:var(--bt-radius-full);background:none;gap:var(--bt-space-2xs)}
.badge.coverage::before{content:'';width:var(--bt-space-xs);height:var(--bt-space-xs);border-radius:var(--bt-radius-full);background:currentColor;flex:0 0 auto}
.dl dd > .badge:only-child{margin-left:calc(-1 * (var(--bt-space-xs) + var(--bt-stroke-hairline)))}

/* ── buttons: every variant sets its own background ─────────────────────── */
.btn{font-size:var(--bt-type-body-sm-size);font-weight:var(--bt-type-h3-weight);line-height:var(--bt-type-body-sm-line);padding:var(--bt-density-control-y) var(--bt-density-control-x);border-radius:var(--bt-radius-md);display:inline-flex;gap:var(--bt-space-xs);align-items:center;justify-content:center;cursor:pointer;border:var(--bt-stroke-hairline) solid transparent;background:var(--bt-action-ghost-bg);color:var(--bt-action-ghost-fg);transition:background var(--bt-motion-fast) var(--bt-motion-ease),border-color var(--bt-motion-fast) var(--bt-motion-ease),color var(--bt-motion-fast) var(--bt-motion-ease)}
.btn.primary{background:var(--bt-action-bg);color:var(--bt-action-fg);border-color:var(--bt-action-bg)}
.btn.primary:hover{background:var(--bt-action-bg-hover);border-color:var(--bt-action-bg-hover)}
.btn.primary:active{background:var(--bt-action-bg-active);border-color:var(--bt-action-bg-active)}
.btn.ghost{background:var(--bt-action-ghost-bg);color:var(--bt-action-ghost-fg);border-color:var(--bt-action-ghost-border)}
.btn.ghost:hover{background:var(--bt-action-ghost-bg-hover);border-color:var(--bt-action-ghost-border-hover)}
.btn.ghost:active{background:var(--bt-action-ghost-bg-active)}
.btn.disabled{background:var(--bt-action-disabled-bg);color:var(--bt-action-disabled-fg);border-color:var(--bt-action-disabled-border);cursor:not-allowed}
.btn.disabled:hover{background:var(--bt-action-disabled-bg);border-color:var(--bt-action-disabled-border)}

/* ── tx-detail debug panel ──────────────────────────────────────────────── */
.debugcard{max-width:var(--bt-layout-prose);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);padding:var(--bt-density-card-pad) var(--bt-density-cell-x);background:var(--bt-surface-raised);box-shadow:var(--bt-elevation-overlay)}
.debugcard .row{display:flex;align-items:center;gap:var(--bt-space-md);flex-wrap:wrap}
.debugcard .note{color:var(--bt-text-default);font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line);margin-top:var(--bt-rhythm-stack);max-width:var(--bt-measure-prose)}
.debugcard .note.spec{max-width:none;margin-top:var(--bt-rhythm-stack);padding-top:var(--bt-space-sm);border-top:var(--bt-stroke-hairline) solid var(--bt-border-subtle);color:var(--bt-text-default)}
/* The producer's own words, one rung quieter than the sentence above them and
   tightened to it, so the pair reads as statement-then-evidence rather than as
   two paragraphs. Same relationship `.notice .reason` gives the explorer's §14
   treatments, which is where the rule is written down. */
.debugcard .note.reason{color:var(--bt-text-muted);margin-top:var(--bt-space-2xs)}
.execlist{list-style:none;margin-top:var(--bt-rhythm-stack);display:flex;flex-direction:column;gap:var(--bt-space-sm)}
.execlist li{display:flex;align-items:center;gap:var(--bt-space-sm);flex-wrap:wrap}
.execlist .sel{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);font-size:var(--bt-type-identifier-size);color:var(--bt-text-muted);min-width:var(--bt-space-3xl)}
.execlist .reason{color:var(--bt-text-muted);font-size:var(--bt-type-body-sm-size);max-width:var(--bt-measure-prose)}

/* ── deferred / notice callouts ─────────────────────────────────────────── */
.stub{max-width:var(--bt-layout-prose);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-md);padding:var(--bt-space-md) var(--bt-density-cell-x);margin-top:var(--bt-rhythm-stack);background:var(--bt-surface-raised);color:var(--bt-text-default);font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line)}
.stub b{color:var(--bt-text-default);font-weight:var(--bt-type-h3-weight)}
.measure{max-width:var(--bt-measure-prose)}

/* ── raw json ───────────────────────────────────────────────────────────── */
pre.raw{max-height:var(--bt-layout-code-max-height);overflow:auto;background:var(--bt-surface-code);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);padding:var(--bt-space-md) var(--bt-density-cell-x);overflow-x:auto;font-family:var(--bt-font-code),var(--bt-font-mono-fallback);font-size:var(--bt-type-code-size);line-height:var(--bt-type-code-line);color:var(--bt-text-code);font-variant-numeric:var(--bt-numeric-features)}

/* ── §14 degraded-state notice ──────────────────────────────────────────── */
/* One block, one tone from the status vocabulary, and never colour alone: the
   row is named in a badge before it is painted (rubric A7). */
.notice{margin-top:var(--bt-rhythm-stack);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-left:var(--bt-stroke-thick) solid var(--bt-border-strong);border-radius:var(--bt-radius-md);padding:var(--bt-space-md) var(--bt-density-cell-x);background:var(--bt-surface-raised);box-shadow:var(--bt-elevation-raised)}
.notice.bad{border-left-color:var(--bt-status-danger-border)}
.notice.warn{border-left-color:var(--bt-status-warning-border)}
.notice.info{border-left-color:var(--bt-status-info-border)}
.notice.muted{border-left-color:var(--bt-status-neutral-border)}
.notice .noticehead{display:flex;align-items:center;gap:var(--bt-space-sm);flex-wrap:wrap;margin-bottom:var(--bt-space-sm)}
.notice p{font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line);color:var(--bt-text-default)}
.notice .reason{color:var(--bt-text-muted);margin-top:var(--bt-space-2xs)}

/* ── cursor pager (§2.2: no ordinal pages, so no page numbers) ───────────── */
.pager{display:flex;align-items:center;justify-content:space-between;gap:var(--bt-space-md);flex-wrap:wrap;margin-top:var(--bt-rhythm-stack)}
.pager .pagerwhere{color:var(--bt-text-muted);font-size:var(--bt-type-body-sm-size);font-variant-numeric:var(--bt-numeric-features)}
.pager .pagerbtns{display:flex;gap:var(--bt-space-sm)}
.btn.sm{font-size:var(--bt-type-caption-size);line-height:var(--bt-type-caption-line);padding:var(--bt-space-2xs) var(--bt-space-sm)}
.linkrow{display:flex;gap:var(--bt-space-sm);flex-wrap:wrap}
.linklist{list-style:none;display:flex;flex-direction:column;gap:var(--bt-space-2xs);margin-top:var(--bt-rhythm-stack)}
.linklist a{color:var(--bt-text-link);text-decoration:underline;text-underline-offset:var(--bt-space-3xs)}

/* ── the shared transactions table (§6) ─────────────────────────────────── */
/* The Debug column is first and never scrolls out of view horizontally: it is
   the primary action, and a table that scrolls it away is the anti-goal rule 1
   names. */
table.txtbl th.act,table.txtbl td.act{position:sticky;left:0;z-index:1;background:var(--bt-surface-raised)}
table.txtbl th.act{background:var(--bt-surface-sunken)}
table.txtbl tbody tr:hover td.act{background:var(--bt-surface-hover)}
table.txtbl td .reason{display:inline-block;margin-left:var(--bt-space-xs);color:var(--bt-text-muted);font-size:var(--bt-type-caption-size)}
/* Reverted rows are visually distinct — they are the population this product
   exists for — and the distinction is a tinted row plus a leading rule, so it
   survives a greyscale render and a colour-vision deficiency alike. */
table.txtbl tbody tr.reverted td{background:var(--bt-status-danger-bg)}
table.txtbl tbody tr.reverted td.act{border-left:var(--bt-stroke-thick) solid var(--bt-status-danger-border)}
table.txtbl tbody tr.reverted:hover td{background:var(--bt-surface-hover)}
table.txtbl tbody tr.partial td.act{border-left:var(--bt-stroke-thick) solid var(--bt-status-warning-border)}
table.tbl td a.addr{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);color:var(--bt-text-link)}
table.tbl td .reason{white-space:normal;max-width:var(--bt-measure-narrow)}

/* ── verified-source browser (§10) ──────────────────────────────────────── */
.filetree{display:flex;gap:var(--bt-space-sm);flex-wrap:wrap;margin-bottom:var(--bt-rhythm-stack)}
.filetree a{border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-sm);padding:var(--bt-space-3xs) var(--bt-space-xs);color:var(--bt-text-link);background:var(--bt-surface-sunken);font-size:var(--bt-type-caption-size)}
.filetree a:hover{border-color:var(--bt-border-accent)}
.codefile{margin-top:var(--bt-rhythm-stack);border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);overflow:hidden;background:var(--bt-surface-code)}
.codehead{display:flex;justify-content:space-between;gap:var(--bt-space-md);padding:var(--bt-space-xs) var(--bt-density-cell-x);background:var(--bt-surface-sunken);border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-default);font-size:var(--bt-type-caption-size)}
.codeview{max-height:var(--bt-layout-code-max-height);overflow:auto;padding:var(--bt-space-sm) 0}
.codeline{display:flex;gap:var(--bt-space-sm);font-family:var(--bt-font-code),var(--bt-font-mono-fallback);font-size:var(--bt-type-code-size);line-height:var(--bt-type-code-line)}
.codeline .gutter{flex:0 0 var(--bt-space-3xl);text-align:right;color:var(--bt-text-subtle);user-select:none;font-variant-numeric:var(--bt-numeric-features)}
.codeline .t{white-space:pre;color:var(--bt-syntax-plain);padding-right:var(--bt-density-cell-x)}
/* The same lexical palette the debugger's source pane uses, in the explorer
   register. One set of roles, so a keyword is the same colour in both. */
.codeview .tk-comment{color:var(--bt-syntax-comment)}
.codeview .tk-keyword{color:var(--bt-syntax-keyword)}
.codeview .tk-type{color:var(--bt-syntax-type)}
.codeview .tk-function{color:var(--bt-syntax-function)}
.codeview .tk-string{color:var(--bt-syntax-string)}
.codeview .tk-number{color:var(--bt-syntax-number)}
.codeview .tk-punct{color:var(--bt-syntax-punctuation)}

/* ── footer links ───────────────────────────────────────────────────────── */
.footlinks{display:flex;gap:var(--bt-space-md);margin-top:var(--bt-space-xs)}
.footlinks a{color:var(--bt-text-link);text-decoration:underline;text-underline-offset:var(--bt-space-3xs)}

/* ── inline marks ───────────────────────────────────────────────────────── */
/* The site's one icon convention (components/icons.nim). Every rule here is a
   consequence of what an inline SVG is, not a look:

   * `currentColor` on the mark means the COLOUR is whatever the surrounding
     text is, so a mark is themed by the token that themes its sentence and
     there is no second colour to keep in step. The heart is the one that
     opts out, below.
   * `display:inline-block`, overriding the `img,svg{display:block}` reset at
     the top of this file. A block-level SVG in a run of text starts its own
     line box; `vertical-align` needs an inline box to have anything to align
     TO, and without it a 16px mark on a 14px line sits low by its descender.
   * `flex:0 0 auto`, because two of the three callers are flex containers
     (`.ctcredit`, `.repolink`) and a mark that shrinks is a mark that
     distorts — an SVG has no intrinsic minimum the way an image does. */
.svgicon{width:var(--bt-space-md);height:var(--bt-space-md);display:inline-block;vertical-align:text-bottom;flex:0 0 auto}
/* The heart is smaller than the logos beside it and it is the accent rather
   than the text colour. Both because it is a WORD in the sentence and not a
   logo at the end of one: at the logos' size it outweighs the clause it sits
   in, and in the text colour it reads as a dingbat someone typed. The accent
   is the site's own colour, and deliberately not `--bt-status-danger-*`: the
   red in this token layer means "this went wrong", and borrowing it for
   affection would make the one red on a page mean two things. */
.svgicon.heart{width:var(--bt-space-sm);height:var(--bt-space-sm);color:var(--bt-accent-default);vertical-align:baseline}

/* ── footer ─────────────────────────────────────────────────────────────── */
.foot{border-top:var(--bt-stroke-hairline) solid var(--bt-border-subtle);margin-top:var(--bt-rhythm-group);padding:var(--bt-rhythm-group) 0;color:var(--bt-text-subtle);font-size:var(--bt-type-body-sm-size);background:var(--bt-surface-raised)}
.foot .inner{display:flex;justify-content:space-between;gap:var(--bt-rhythm-stack);flex-wrap:wrap}
.foot code{color:var(--bt-text-code)}

/* ── footer: the provenance strip ───────────────────────────────────────── */
/* Who built it, what it runs on, and where the source is — one column, because
   the three statements are one claim and a reader who has found the first has
   found all three. */
.footcredit{display:flex;flex-direction:column;align-items:flex-start;gap:var(--bt-space-xs)}
.footcredit a{color:var(--bt-text-link);text-decoration:underline;text-underline-offset:var(--bt-space-3xs)}
.footcredit a:hover{color:var(--bt-text-link-hover)}
/* The credo is ordinary running text, NOT a flex row: "Built with ♥ by …" is a
   sentence, and a flex container turns each run between two marks into an
   anonymous item that can be broken and re-gapped independently of the words
   around it. Only the two pieces that are a name PLUS a mark are flex, and
   only so the mark cannot be separated from the name it belongs to. */
.ctcredit,.repolink{display:inline-flex;align-items:center;gap:var(--bt-space-2xs);white-space:nowrap}
.repolink{text-decoration:underline;text-underline-offset:var(--bt-space-3xs)}

/* ── §13: below 900px the transactions table becomes stacked cards ───────── */
/* "All tables virtualised; below 900 px they become stacked cards with the
   primary action (Debug) and status retained." Debug leads each card and the
   status closes it, which is the pair §13 names — and the horizontal scroll
   that would otherwise hide the far columns is gone rather than tightened. */
@media (max-width:900px){
  .tablewrap:has(table.txtbl){overflow-x:visible;border:0;background:none;box-shadow:none}
  table.txtbl{display:block;font-size:var(--bt-type-body-sm-size)}
  table.txtbl thead{display:none}
  table.txtbl tbody{display:block}
  table.txtbl tbody tr{display:block;border:var(--bt-stroke-hairline) solid var(--bt-border-default);border-radius:var(--bt-radius-lg);background:var(--bt-surface-raised);box-shadow:var(--bt-elevation-raised);padding:var(--bt-space-sm) var(--bt-density-cell-x);margin-bottom:var(--bt-space-sm)}
  table.txtbl tbody tr.reverted{border-color:var(--bt-status-danger-border)}
  table.txtbl td{display:flex;justify-content:space-between;align-items:baseline;gap:var(--bt-space-md);white-space:normal;border-bottom:0;padding:var(--bt-space-3xs) 0;text-align:left}
  table.txtbl td.num{text-align:left}
  table.txtbl td::before{content:attr(data-label);color:var(--bt-text-muted);font-family:var(--bt-font-sans),var(--bt-font-sans-fallback);font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;flex:0 0 auto}
  /* Debug leads the card at full width, so the primary action is the first
     thing in every card rather than a value in a labelled row. */
  table.txtbl td.act{position:static;display:block;background:none;padding-bottom:var(--bt-space-sm);border-left:0}
  table.txtbl td.act::before{content:none}
  table.txtbl td.act .btn{width:100%}
  table.txtbl tbody tr.reverted td,table.txtbl tbody tr.reverted:hover td{background:none}
  /* The desktop treatment marks a non-successful row with a rule down the LEFT
     EDGE of its Debug cell. In card mode that cell is a full-width block and
     the rule became a stub above the button; the card's own border carries the
     status instead, so the rule is reset at matching specificity. */
  table.txtbl tbody tr.reverted td.act,table.txtbl tbody tr.partial td.act{border-left:0}
  table.txtbl tbody tr.partial{border-color:var(--bt-status-warning-border)}
  /* A revert reason is prose containing one long unbreakable token — the
     failing expression. As a flex item beside its badge it could not shrink
     below that token's width, so at 375px "assert(did_survive_positive" and
     "satisfied at src/main.nr:35" ran past the card's own border, which on a
     REVERTED row is the red border that carries the status. `min-width:0`
     lets the item shrink; `overflow-wrap:anywhere` gives the token somewhere
     to break when it still does not fit. `max-width:none` is unchanged: the
     44ch measure is for the desktop table's reason column. */
  table.txtbl td .reason{margin-left:0;max-width:none;min-width:0;overflow-wrap:anywhere}
}

/* Breakpoints are written as literals because CSS cannot read a custom
   property in a media condition. */
@media (max-width:720px){
  .dl{grid-template-columns:1fr}
  .dl dt{border-bottom:0;padding-bottom:0}
  .dl dd{padding-top:var(--bt-space-2xs)}
  .hero{padding:var(--bt-rhythm-group) 0}
  .sec-title.next{margin-top:var(--bt-rhythm-group)}
  .nav .links a.opt{display:none}
}
"""
