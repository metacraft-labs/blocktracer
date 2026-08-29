## The debug route's stylesheet — the product register's Layer 2.
##
## Appended to `globalCss` by `components/layout.nim`, so the reset, the type
## scale, `.badge`, `.btn` and the focus treatment are shared with the explorer
## exactly as Design-System.md §2 requires: "the two registers share type
## ratios, the spacing scale, radii, focus treatment, motion and the accent
## family. What differs is DENSITY, surface colour and default theme."
##
## Nothing below re-declares any of those three. They arrive through
## `<html data-register="debugger">`, which the token layer already keys on —
## `--bt-density-*` drops to the dense set and the default theme flips to dark
## — so the register change is a change of attribute value and not a second
## component library. Every value here is `var(--bt-*)`; the literals are `0`,
## `100%`, `1fr`, `auto` and the media breakpoints, which is the same set
## `styles.nim` documents.
##
## ## The weight ladder
##
## `defaultReplayLayout()` uses weights 1, 2, 3 and 9. A flex fraction cannot
## come from a custom property applied per element without an inline `style`
## attribute, and an inline style is a design value no token layer can reach
## (check A5). So the fractions are a fixed ladder of classes and
## `debugger.weightClass` refuses a weight the ladder has no rule for — a
## layout this stylesheet cannot render fails the build instead of rendering
## at the wrong proportions.
##
## ## Tabs without JavaScript
##
## `lnStack` becomes `:target` tabs. The panels are emitted in reverse and put
## back with `order`, because a targeted alternate has to hide the default and
## CSS reaches only forward siblings. The whole session is therefore navigable
## with scripting off, which is what makes the static route the debugger's
## honest first frame.

const debugRouteCss* = """
/* ── the shell ──────────────────────────────────────────────────────────── */
/* Full viewport with no page scroll. `height:100%` down the chain rather than
   a viewport unit: `vh` is a raw length, and the chain says the same thing. */
html[data-register="debugger"],
[data-register="debugger"] body{height:100%;overflow:hidden}
[data-register="debugger"] .dbg{display:flex;flex-direction:column;height:100%;min-height:0}

/* ── identity bar ───────────────────────────────────────────────────────── */
.dbgbar{flex:0 0 auto;display:flex;align-items:center;gap:var(--bt-space-md);
  height:var(--bt-layout-nav-height);padding:0 var(--bt-layout-gutter);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-default);
  background:var(--bt-surface-raised)}
.dbgback{color:var(--bt-text-link);font-size:var(--bt-type-body-sm-size);
  white-space:nowrap;transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.dbgback:hover{color:var(--bt-text-link-hover);text-decoration:underline;
  text-underline-offset:var(--bt-space-3xs)}
.dbgid{color:var(--bt-text-strong);font-size:var(--bt-type-identifier-size);
  word-break:normal}
.dbgblock{color:var(--bt-text-muted);font-size:var(--bt-type-caption-size);
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-variant-numeric:var(--bt-numeric-features);white-space:nowrap}
.dbglang{color:var(--bt-text-subtle);font-size:var(--bt-type-label-size);
  letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase}
.dbgspacer{flex:1 1 auto}
.btn.sm{font-size:var(--bt-type-label-size);line-height:var(--bt-type-label-line);
  padding:var(--bt-space-3xs) var(--bt-space-xs)}

/* ── banners: one component, two severities ─────────────────────────────── */
.dbgbanner{flex:0 0 auto;display:flex;align-items:baseline;
  gap:var(--bt-space-sm);padding:var(--bt-density-cell-y) var(--bt-layout-gutter);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-default);
  font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line)}
.dbgbanner.bad{background:var(--bt-status-danger-bg);color:var(--bt-status-danger-fg);
  border-bottom-color:var(--bt-status-danger-border)}
.dbgbanner.warn{background:var(--bt-status-warning-bg);color:var(--bt-status-warning-fg);
  border-bottom-color:var(--bt-status-warning-border)}
.dbgbanner .bannertitle{font-weight:var(--bt-type-h3-weight);white-space:nowrap}
.dbgbanner .bannertext{color:inherit;max-width:var(--bt-measure-prose)}

/* ── the honest loading line (§8: phase, never a spinner) ───────────────── */
.enginenotice{flex:0 0 auto;display:flex;align-items:center;
  gap:var(--bt-space-md);flex-wrap:wrap;
  padding:var(--bt-density-cell-y) var(--bt-layout-gutter);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  background:var(--bt-surface-sunken);
  font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line)}
.enginetext{color:var(--bt-text-muted);max-width:var(--bt-measure-prose)}
.engineorigin{color:var(--bt-text-subtle);
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-label-size);word-break:break-all}
.enginenotice .phaserail{margin-top:0}

/* ── the pane region ────────────────────────────────────────────────────── */
.dbgmain{flex:1 1 0;display:flex;min-height:0;min-width:0;
  gap:var(--bt-space-2xs);padding:var(--bt-space-2xs);
  background:var(--bt-surface-canvas)}
.ln{display:flex;min-width:0;min-height:0;gap:var(--bt-space-2xs)}
.ln.row{flex-direction:row}
.ln.col{flex-direction:column}

/* The weight ladder. `defaultReplayLayout()` uses 1, 2, 3 and 9. */
.w1{flex:1 1 0;min-width:0;min-height:0}
.w2{flex:2 1 0;min-width:0;min-height:0}
.w3{flex:3 1 0;min-width:0;min-height:0}
.w4{flex:4 1 0;min-width:0;min-height:0}
.w5{flex:5 1 0;min-width:0;min-height:0}
.w6{flex:6 1 0;min-width:0;min-height:0}
.w7{flex:7 1 0;min-width:0;min-height:0}
.w8{flex:8 1 0;min-width:0;min-height:0}
.w9{flex:9 1 0;min-width:0;min-height:0}
.w10{flex:10 1 0;min-width:0;min-height:0}
.w11{flex:11 1 0;min-width:0;min-height:0}
.w12{flex:12 1 0;min-width:0;min-height:0}

/* ── one pane ───────────────────────────────────────────────────────────── */
.pane{display:flex;flex-direction:column;min-width:0;min-height:0;
  border:var(--bt-stroke-hairline) solid var(--bt-border-default);
  border-radius:var(--bt-radius-md);background:var(--bt-surface-raised);
  overflow:hidden}
.panehead{flex:0 0 auto;display:flex;align-items:center;justify-content:space-between;
  gap:var(--bt-space-xs);
  padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  background:var(--bt-surface-sunken);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
.panetitle{font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);
  line-height:var(--bt-type-label-line);letter-spacing:var(--bt-type-label-tracking);
  text-transform:uppercase;color:var(--bt-text-muted)}
/* The pane-header dismiss rule is GONE, with the control it styled — see
   `pages/debug.nim` for why that control could not be honoured. A rule kept
   for an element that no longer exists is a standing invitation to re-add it.
   Note also that this stylesheet is INLINED into the page, so a selector, or
   even a comment, naming a removed affordance keeps its name in the served
   bytes; `test_debug_route` asserts over those bytes. */
.panebody{flex:1 1 0;min-height:0;overflow:auto}
.panenote{padding:var(--bt-density-card-pad) var(--bt-density-cell-x);
  color:var(--bt-text-muted);font-size:var(--bt-type-body-sm-size);
  line-height:var(--bt-type-body-sm-line);max-width:var(--bt-measure-prose)}

/* ── tabs (a stack) ─────────────────────────────────────────────────────── */
.ln.stack{display:flex;flex-direction:column;
  border:var(--bt-stroke-hairline) solid var(--bt-border-default);
  border-radius:var(--bt-radius-md);background:var(--bt-surface-raised);
  overflow:hidden}
.ln.stack > .pane{border:0;border-radius:0;flex:1 1 0}
.ln.stack > .pane > .panehead{display:none}
.stacktabs{order:-1;flex:0 0 auto;display:flex;gap:0;
  background:var(--bt-surface-sunken);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
.stacktab{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);
  letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;
  color:var(--bt-text-subtle);
  border-bottom:var(--bt-stroke-thick) solid transparent;
  transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.stacktab:hover{color:var(--bt-text-default);background:var(--bt-surface-hover)}
/* Default tab and default panel. */
.stackpanel.alt{display:none}
.stackpanel.def{display:flex}
.stacktabs > .stacktab:first-child{color:var(--bt-text-strong);
  border-bottom-color:var(--bt-accent-default)}
/* A targeted alternate takes over, and reaches forward to correct both the
   default panel and the tab strip. */
.stackpanel.alt:target{display:flex}
.stackpanel.alt:target ~ .stackpanel.def{display:none}
.stackpanel.alt:target ~ .stacktabs > .stacktab:first-child{
  color:var(--bt-text-subtle);border-bottom-color:transparent}
.stackpanel.alt:target ~ .stacktabs > .stacktab:last-child{
  color:var(--bt-text-strong);border-bottom-color:var(--bt-accent-default)}

/* ── source pane ────────────────────────────────────────────────────────── */
/* `height:100%` and not `flex:1` alone: `.srcwrap` is a BLOCK child of
   `.panebody`, so it has no flex parent to grow into, and a chain of
   `flex:1 1 0` items under an auto-height ancestor resolves to zero — which
   renders the pane empty rather than short. The explicit height gives the
   chain a definite one to divide. */
.srcwrap{display:flex;flex-direction:column;min-height:0;height:100%;
  position:relative}
/* A code line that runs past the pane edge is CUT, and at rest nothing said
   so — five reviewers read the clipped lines as breakage rather than as
   scrollable overflow, because a capture (and a trackpad) hides the
   scrollbar. The fade is the affordance: it says "there is more to the right"
   without spending a row on a scrollbar the platform may never draw.
   `pointer-events:none` so it cannot eat a click on the code beneath it. */
.srcwrap::after{content:"";position:absolute;top:0;right:0;bottom:0;
  width:var(--bt-space-2xl);pointer-events:none;
  background:linear-gradient(to right, transparent, var(--bt-surface-code))}
/* One panel per document, switched by `:target`. The ACTIVE document is
   emitted last so every alternate can reach forward and hide it — CSS has
   only a forward sibling combinator. Each panel carries its OWN tab strip
   with its own tab marked, which is what makes the active tab correct for any
   number of documents without a per-document rule. */
.srcdoc{display:flex;flex-direction:column;min-height:0;flex:1 1 0}
.srcdoc.alt{display:none}
.srcdoc.alt:target{display:flex}
.srcdoc.alt:target ~ .srcdoc.def{display:none}
.srctabs{display:flex;gap:var(--bt-space-3xs);flex-wrap:wrap;flex:0 0 auto;
  padding:var(--bt-space-3xs) var(--bt-density-cell-x);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  background:var(--bt-surface-sunken)}
/* A tab is a real link to its document, so it gets a real hit area and a real
   hover — the strip used to be four inert `<span>`s naming four files of which
   one was reachable. */
.srctab{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-label-size);color:var(--bt-text-subtle);
  padding:var(--bt-space-3xs) var(--bt-space-xs);
  border-radius:var(--bt-radius-xs);
  border-bottom:var(--bt-stroke-thick) solid transparent;
  transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.srctab:hover{color:var(--bt-text-default);background:var(--bt-surface-hover)}
.srctab.on{color:var(--bt-text-strong);border-bottom-color:var(--bt-accent-default)}
/* The pane opens part-way into the file, and says so rather than leaving the
   reader to infer it from a first line number that is not 1. */
.srcfrom{padding:var(--bt-space-2xs) var(--bt-density-cell-x);
  color:var(--bt-text-muted);font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-label-size);line-height:var(--bt-type-body-sm-line);
  background:var(--bt-surface-sunken);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
/* The code body is the pane's own scroll container on BOTH axes, so a long
   line scrolls the code and not the tab strip above it. */
.src{font-family:var(--bt-font-code),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-code-size);line-height:var(--bt-type-code-line);
  color:var(--bt-text-code);background:var(--bt-surface-code);
  padding:var(--bt-space-2xs) 0;min-width:0;flex:1 1 0;overflow:auto}
/* `min-width:max-content` makes the rows as wide as the widest line, so the
   current-line fill and the executed-line stripe extend across the whole
   scrolled width instead of stopping at the pane edge — a row highlight that
   ends mid-line reads as a rendering fault once the pane is scrolled. */
.srcline{display:flex;align-items:flex-start;gap:var(--bt-space-xs);
  padding:0 var(--bt-density-cell-x);white-space:pre;
  min-width:max-content;
  border-left:var(--bt-stroke-thick) solid transparent}
.srcline .n{flex:0 0 var(--bt-space-2xl);text-align:right;
  color:var(--bt-text-subtle);font-variant-numeric:var(--bt-numeric-features);
  user-select:none}
.srcline .m{flex:0 0 var(--bt-space-md);color:var(--bt-text-subtle);
  text-align:center;user-select:none}
.srcline .t{font:inherit;color:var(--bt-syntax-plain);white-space:pre;min-width:0}
.srcline.hit{background:var(--bt-surface-sunken)}
.srcline.hit .m{color:var(--bt-accent-subtle)}
.srcline.cur{background:var(--bt-surface-selected);
  border-left-color:var(--bt-accent-default)}
.srcline.cur .n,.srcline.cur .m{color:var(--bt-accent-default)}
.srcline.cur .t{color:var(--bt-text-strong)}
/* The lexical palette (Design-System.md §7: "syntax highlighting comes from the
   product lineage's editor tokens in BOTH themes"). One rule per TokenKind that
   `debugger.tokenClass` can return; `tkPlain` has none, because it is emitted
   as a bare text node and takes `.t`'s colour above.

   These sit on the SPAN, so they win over `.srcline.cur .t` by inheritance
   rather than by specificity — a token keeps its hue on the current line,
   where the background is `--bt-surface-selected` rather than
   `--bt-surface-code`. Every role was checked against all three backgrounds a
   source line can have (code, sunken for an executed line, selected for the
   current one) in both themes — 48 pairs, and the weakest is 5.01:1 (dark
   comment on the current line's `--bt-surface-selected`). Colour is the only
   channel: the text is fully legible without it, so unlike a status badge this
   needs no redundant glyph. */
.src .tk-comment{color:var(--bt-syntax-comment)}
.src .tk-keyword{color:var(--bt-syntax-keyword)}
.src .tk-type{color:var(--bt-syntax-type)}
.src .tk-function{color:var(--bt-syntax-function)}
.src .tk-string{color:var(--bt-syntax-string)}
.src .tk-number{color:var(--bt-syntax-number)}
.src .tk-punct{color:var(--bt-syntax-punctuation)}
/* The inline value overlay's slot. Nothing produces annotations yet; the rule
   exists so that when a producer does, the line does not have to change. */
.srcline .ann{display:inline-flex;gap:var(--bt-space-2xs);
  margin-left:var(--bt-space-md);white-space:nowrap}
.srcline .annv{font-size:var(--bt-type-label-size);
  padding:0 var(--bt-space-3xs);border-radius:var(--bt-radius-xs);
  background:var(--bt-status-info-bg);color:var(--bt-status-info-fg);
  border:var(--bt-stroke-hairline) solid var(--bt-status-info-border)}
.srcnone{padding:var(--bt-density-card-pad) var(--bt-density-cell-x)}
.srcnone .btn{margin-top:var(--bt-rhythm-stack)}

/* ── call trace ─────────────────────────────────────────────────────────── */
.ct{font-size:var(--bt-density-data-size);min-width:0}
.cthead,.ctrow,.ctfoot{display:flex;align-items:baseline;
  gap:var(--bt-space-sm);
  padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
.cthead{background:var(--bt-surface-sunken);color:var(--bt-text-muted);
  font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);
  letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;
  position:sticky;top:0}
.ctrow{border-left:var(--bt-stroke-thick) solid transparent}
.ctrow:hover{background:var(--bt-surface-hover)}
.ctrow.cur{background:var(--bt-surface-selected);
  border-left-color:var(--bt-accent-default)}
.ctfn{flex:1 1 auto;min-width:0;display:flex;align-items:baseline;
  gap:var(--bt-space-xs);overflow:hidden}
.ctname{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  color:var(--bt-text-strong);white-space:nowrap;overflow:hidden;
  text-overflow:ellipsis}
.ctrow.cur .ctname{color:var(--bt-accent-default)}
.ctmod{color:var(--bt-text-subtle);font-size:var(--bt-type-label-size);
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ctcost{flex:0 0 auto;text-align:right;color:var(--bt-text-default);
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-variant-numeric:var(--bt-numeric-features);
  min-width:var(--bt-space-3xl)}
/* The unit is the COLUMN's, carried once by the header. It used to repeat on
   every row, spending width that the frame column — the one that actually
   truncates — needed. */
.ctunit{color:var(--bt-text-subtle);font-size:var(--bt-type-label-size);
  font-weight:var(--bt-type-body-weight);letter-spacing:normal;
  text-transform:none}

/* Depth is indentation, and the ladder is LINEAR.
   It used to be the spacing scale, which is not: `md → xl → 2xl → 3xl → 4xl`
   is 16 → 32 → 48 → 60 → 100 px, so the rungs stepped by 16, 16, 12, 40. Depth
   3 to depth 4 moved three quarters of a character; depth 4 to depth 5 moved
   two and a half characters. One level of nesting therefore meant a different
   amount of indentation depending on where in the trace it occurred, which is
   the one thing an indent ladder may not do: it ranks EQUAL things — each rung
   is exactly one call — and so it has to step equally. A spacing scale ranks
   unequal ones, which is why it grows, and why it is the wrong scale here.
   Beyond the ladder the rows carried a `d6`, `d7`,
   … no rule answered, which resolved to NO indentation — so a trace deeper
   than the ladder did not render as deep, it rendered as FLAT, which is
   indistinguishable from a correct shallow trace. `debugger.depthClass`
   clamps to `MaxIndentDepth` and adds `.deeper`, and the ladder below covers
   every class it can now emit. */
.ctrow.d0 .ctfn{padding-left:0}
.ctrow.d1 .ctfn{padding-left:calc(var(--bt-space-md) * 1)}
.ctrow.d2 .ctfn{padding-left:calc(var(--bt-space-md) * 2)}
.ctrow.d3 .ctfn{padding-left:calc(var(--bt-space-md) * 3)}
.ctrow.d4 .ctfn{padding-left:calc(var(--bt-space-md) * 4)}
.ctrow.d5 .ctfn{padding-left:calc(var(--bt-space-md) * 5)}
.ctrow.d6 .ctfn{padding-left:calc(var(--bt-space-md) * 6)}
.ctrow.d7 .ctfn{padding-left:calc(var(--bt-space-md) * 7)}
.ctrow.d8 .ctfn{padding-left:calc(var(--bt-space-md) * 8)}
/* A frame deeper than the ladder is MARKED as clamped rather than drawn at a
   depth it is not at. The rule is what stops the clamp from becoming a
   quieter version of the bug it replaced. */
.ctrow.deeper .ctname::before{content:"⋯ ";color:var(--bt-text-subtle)}
/* A guide rule per row, so depth is readable by eye rather than by comparing
   left edges character by character. */
.ctrow:not(.d0):not(.flat) .ctfn{
  border-left:var(--bt-stroke-hairline) solid var(--bt-border-default);
  margin-left:var(--bt-space-2xs)}
.ctfoot{border-bottom:0;color:var(--bt-text-subtle);
  font-size:var(--bt-type-label-size);justify-content:space-between}
.ctsort{color:var(--bt-text-link);text-decoration:underline;
  text-underline-offset:var(--bt-space-3xs)}
.ctsort:hover{color:var(--bt-text-link-hover)}

/* The cost-sorted view, on the same `:target` mechanism as the pane tabs.
   `.ctview.def` is emitted LAST so the alternate can reach forward and hide
   it. "Sort by cost" is now a link that sorts; it used to be a `<span>` with
   link colour and an underline and no behaviour at all. */
.ctview.alt{display:none}
.ctview.def{display:block}
.ctview.alt:target{display:block}
.ctview.alt:target ~ .ctview.def{display:none}

/* A dense pane sets its own data size, and `.num` must not override it.
   `styles.nim` gives `.num` the explorer's numeric size and line-height, which
   inside a 12px/1.35 debugger row resolves to 14px/1.5 — so the row grew to
   30px, the COST number rendered larger than the function name it annotates,
   and the three list panes stopped sharing a pitch (call trace 30, event log
   30, state 25) where the desktop app keeps every call-trace row at one size
   and one pitch. The class still carries the tabular-figure treatment, which
   is the part these columns actually want. */
.ct .num,.st .num,.ev .num,.mddl .num,.dc .num{
  font-size:inherit;line-height:inherit}

/* ── state ──────────────────────────────────────────────────────────────── */
.st{font-size:var(--bt-density-data-size)}
.strow{display:flex;align-items:baseline;gap:var(--bt-space-sm);
  padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  border-left:var(--bt-stroke-thick) solid transparent}
.strow:hover{background:var(--bt-surface-hover)}
/* Linear, and covering every class `debugger.depthClass` can emit — the SAME
   ladder as the call trace, so one level of nesting means one indent step in
   both panes.
   It was `d1` (lg, 24px) and `d2` (2xl, 48px) only. A value nested three deep
   — which any struct-of-struct produces — got a `d3` no rule answered, so it
   fell back to the row's own cell padding and rendered at the indent of a
   TOP-LEVEL value: not one rung short, but all the way flat, and nothing said
   so. The desktop app indents state by a flat 16px per level and does not
   stop. */
.strow.d1{padding-left:calc(var(--bt-space-md) * 1)}
.strow.d2{padding-left:calc(var(--bt-space-md) * 2)}
.strow.d3{padding-left:calc(var(--bt-space-md) * 3)}
.strow.d4{padding-left:calc(var(--bt-space-md) * 4)}
.strow.d5{padding-left:calc(var(--bt-space-md) * 5)}
.strow.d6{padding-left:calc(var(--bt-space-md) * 6)}
.strow.d7{padding-left:calc(var(--bt-space-md) * 7)}
.strow.d8{padding-left:calc(var(--bt-space-md) * 8)}
.strow.deeper .stname::before{content:"⋯ ";color:var(--bt-text-subtle)}
.strow.chg{border-left-color:var(--bt-accent-default)}
/* `overflow-wrap:anywhere` and not `word-break:break-all`: a long identifier
   has to be able to break, but break-all also breaks SHORT ones that would
   have fitted on the next line, which is what shattered names across rows. */
.stname{flex:0 0 auto;font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  color:var(--bt-text-strong);overflow-wrap:anywhere;min-width:0}
/* The type is the last column and a fixed one, so it can be scanned down the
   pane rather than landing wherever the name happens to end. */
.sttype{flex:0 0 var(--bt-space-4xl);text-align:right;
  color:var(--bt-text-subtle);font-size:var(--bt-type-label-size);
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.stval{flex:1 1 auto;min-width:0;text-align:right;
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-variant-numeric:var(--bt-numeric-features);
  color:var(--bt-text-code);overflow-wrap:anywhere}
.strow.chg .stval{color:var(--bt-accent-default)}

/* ── event log: four kinds, distinguished by glyph, weight and rule ─────── */
.ev{font-size:var(--bt-density-data-size)}
.evrow{display:flex;align-items:baseline;gap:var(--bt-space-sm);
  padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  border-left:var(--bt-stroke-thick) solid transparent}
.evrow:hover{background:var(--bt-surface-hover)}
.evrow.cur{background:var(--bt-surface-selected);
  border-left-color:var(--bt-accent-default)}
.evglyph{flex:0 0 var(--bt-space-md);text-align:center}
.evkind{flex:0 0 var(--bt-space-3xl);font-size:var(--bt-type-label-size);
  font-weight:var(--bt-type-label-weight);letter-spacing:var(--bt-type-label-tracking);
  text-transform:uppercase;color:var(--bt-text-subtle)}
.evstep{flex:0 0 var(--bt-space-2xl);text-align:right;color:var(--bt-text-subtle);
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-variant-numeric:var(--bt-numeric-features)}
.evlabel{flex:0 0 auto;font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  color:var(--bt-text-strong);word-break:break-all}
.evdetail{flex:1 1 auto;min-width:0;color:var(--bt-text-muted);
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.evrow.k-call .evglyph{color:var(--bt-accent-default)}
.evrow.k-storageWrite{background:var(--bt-surface-sunken)}
.evrow.k-storageWrite .evglyph{color:var(--bt-status-info-fg)}
.evrow.k-event .evglyph{color:var(--bt-status-success-fg)}
.evrow.k-output .evglyph{color:var(--bt-text-subtle)}
.evrow.k-output .evlabel{font-weight:var(--bt-type-body-weight);
  color:var(--bt-text-muted)}
.evrow.k-revert{background:var(--bt-status-danger-bg);
  border-left-color:var(--bt-status-danger-border);
  border-top:var(--bt-stroke-thick) solid var(--bt-status-danger-border)}
.evrow.k-revert .evglyph,.evrow.k-revert .evkind,.evrow.k-revert .evlabel{
  color:var(--bt-status-danger-fg);font-weight:var(--bt-type-h3-weight)}
.evrow.k-revert .evdetail{color:var(--bt-status-danger-fg)}

/* ── debug controls ─────────────────────────────────────────────────────── */
.dc{display:flex;align-items:center;gap:var(--bt-space-md);
  padding:var(--bt-density-control-y) var(--bt-density-control-x);
  height:100%}
.dcbtns{flex:0 0 auto;display:flex;gap:var(--bt-space-3xs)}
.dcbtn{display:inline-flex;align-items:center;justify-content:center;
  min-width:var(--bt-space-lg);
  padding:var(--bt-space-3xs) var(--bt-space-xs);
  border:var(--bt-stroke-hairline) solid var(--bt-border-default);
  border-radius:var(--bt-radius-sm);background:var(--bt-action-ghost-bg);
  color:var(--bt-action-ghost-fg);
  transition:background var(--bt-motion-fast) var(--bt-motion-ease)}
.dcbtn:hover{background:var(--bt-action-ghost-bg-hover);
  border-color:var(--bt-action-ghost-border-hover)}
.dcbtn.off{background:var(--bt-action-disabled-bg);
  color:var(--bt-action-disabled-fg);border-color:var(--bt-action-disabled-border);
  cursor:not-allowed}
.dcglyph{font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line)}
.dctl{flex:1 1 auto;min-width:0;display:flex;align-items:center;
  gap:var(--bt-stroke-hairline);height:var(--bt-space-md)}
/* The unfilled track was `--bt-border-subtle`, which measures 1.17:1 in dark
   and 1.67:1 in light — below the 3:1 floor for a non-text element. The
   scrubber's extent is the one thing it exists to express, and an invisible
   track expresses none of it: the control read as four floating dashes. */
.dctl .tick{flex:1 1 0;height:var(--bt-space-2xs);
  background:var(--bt-border-default);border-radius:var(--bt-radius-xs)}
.dctl .tick.on{background:var(--bt-accent-subtle);height:var(--bt-space-sm)}
/* The PLAYHEAD. The elapsed run says how far; this says where, and they are
   different claims — a filled run alone is a progress bar, and a progress bar
   at 10% on a page that is loading an 18 MB engine reads as the engine's
   loading, not as position in a trace. Full track height and the strong accent
   so it is the most legible mark in the control. */
.dctl .tick.at{background:var(--bt-accent-default);height:100%;
  min-width:var(--bt-stroke-thick);border-radius:var(--bt-radius-xs);
  flex:0 0 auto}
.dcstatus{flex:0 0 auto;display:flex;align-items:baseline;gap:var(--bt-space-sm)}
.dcphase{color:var(--bt-text-default);font-size:var(--bt-type-body-sm-size)}
.dcsteps{color:var(--bt-text-subtle);
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-variant-numeric:var(--bt-numeric-features);
  font-size:var(--bt-type-label-size)}

/* ── metadata pane ──────────────────────────────────────────────────────── */
.md{padding:var(--bt-density-cell-y) 0}
.mdhero{display:flex;align-items:center;gap:var(--bt-space-sm);flex-wrap:wrap;
  padding:0 var(--bt-density-cell-x) var(--bt-density-cell-y)}
.mdhash{color:var(--bt-text-strong);font-size:var(--bt-type-identifier-size)}
/* The full hash under the truncation. `break-all` and not `hidden`: it is 66
   characters in a pane column, and a hash clipped mid-string is a hash a
   reader cannot check against the one they arrived with. Same treatment the
   pane's own long identifier values get (`.mddl dd .identifier`). */
.mdfull{padding:0 var(--bt-density-cell-x) var(--bt-density-cell-y);
  color:var(--bt-text-muted);font-size:var(--bt-type-body-sm-size);
  line-height:var(--bt-type-body-sm-line);word-break:break-all}
/* The reason's colour follows the OUTCOME, never the presence of a reason.
   `.bad` is a revert; `.note` is a status reason on a transaction that did not
   fail, which the demo's Aztec split is. */
.mdrevert{padding:0 var(--bt-density-cell-x) var(--bt-density-cell-y);
  font-size:var(--bt-type-body-sm-size)}
.mdrevert.bad{color:var(--bt-status-danger-fg)}
.mdrevert.note{color:var(--bt-text-muted)}
.mddl{display:grid;grid-template-columns:auto minmax(0,1fr);gap:0}
.mddl dt{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);
  letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;
  color:var(--bt-text-subtle);white-space:nowrap;
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
/* `word-break:break-all` applied to the whole cell broke WORDS as well as
   hashes: `mana (FeeJuice)` came out as `mana (Fe` / `eJuice)`, which three
   reviewers reported independently. Only an identifier needs to break at an
   arbitrary character, and only an identifier is monospace enough for the
   break to stay legible, so the aggressive rule is scoped to `.identifier`
   and the cell itself breaks between words. */
.mddl dd{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  font-size:var(--bt-density-data-size);text-align:right;
  overflow-wrap:break-word;
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
.mddl dd .identifier{word-break:break-all}
.mddl dd .muted{white-space:nowrap}
.mddl dd a{color:var(--bt-text-link);text-decoration:underline;
  text-underline-offset:var(--bt-space-3xs)}
.mdexec{padding:var(--bt-density-cell-y) var(--bt-density-cell-x)}
.mdexectitle{display:block;font-size:var(--bt-type-label-size);
  font-weight:var(--bt-type-label-weight);letter-spacing:var(--bt-type-label-tracking);
  text-transform:uppercase;color:var(--bt-text-subtle);
  margin-bottom:var(--bt-space-2xs)}
.mdexecrow{display:flex;align-items:baseline;gap:var(--bt-space-xs);
  flex-wrap:wrap;margin-top:var(--bt-space-2xs)}
.mdexecrow .sel{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-label-size);color:var(--bt-text-muted)}
.mdexecrow .reason{flex:1 1 100%;color:var(--bt-text-subtle);
  font-size:var(--bt-type-label-size);line-height:var(--bt-type-body-sm-line)}
/* §7.2's remaining facts — the decoded input and the chain-native payload —
   as sections of the same pane. They are here rather than only on the
   metadata page because §7.0 makes the transaction route land in the session
   wherever a trace is published, so a fact that lived only on that page would
   be one the product stopped serving. The section heading reuses the
   execution list's, because it is the same kind of label. */
.mdsec{padding:var(--bt-density-cell-y) var(--bt-density-cell-x)}
.mdsec .mddl{margin-top:var(--bt-space-2xs)}
.mdsec .mddl dt,.mdsec .mddl dd{padding-left:0;padding-right:0}
.mdsec .panenote{padding:var(--bt-space-2xs) 0 0}
.mdsec pre.raw{margin-top:var(--bt-space-2xs);
  border-radius:var(--bt-radius-md);padding:var(--bt-density-card-pad)}

/* ── the states with no session ─────────────────────────────────────────── */
.nostate{padding:var(--bt-density-card-pad) var(--bt-density-cell-x)}
.norow{display:flex;align-items:center;gap:var(--bt-space-md);flex-wrap:wrap;
  margin-top:var(--bt-rhythm-stack)}
.norow .panenote{padding:0;flex:1 1 var(--bt-measure-narrow)}
.phaserail{display:flex;gap:var(--bt-space-sm);flex-wrap:wrap;
  align-items:center;margin-top:var(--bt-rhythm-group)}
.phaserail .phase{font-size:var(--bt-type-label-size);
  font-weight:var(--bt-type-label-weight);letter-spacing:var(--bt-type-label-tracking);
  text-transform:uppercase;color:var(--bt-text-subtle);
  padding:var(--bt-space-3xs) var(--bt-space-xs);
  border:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  border-radius:var(--bt-radius-full)}
.phaserail .phase.on{color:var(--bt-text-strong);
  border-color:var(--bt-accent-default);background:var(--bt-surface-selected)}

/* ── the embedded demo on the home page ─────────────────────────────────── */
/* Design-System §2 makes the register crossing deliberate, so the embed is a
   bounded, product-register panel inside an explorer-register page. */
.livedemo{margin-top:var(--bt-rhythm-group);
  border:var(--bt-stroke-hairline) solid var(--bt-border-strong);
  border-radius:var(--bt-radius-lg);overflow:hidden;
  box-shadow:var(--bt-elevation-overlay);
  background:var(--bt-surface-canvas)}
.livedemo .dbgmain{height:var(--bt-layout-code-max-height)}
.livedemofoot{display:flex;align-items:center;justify-content:space-between;
  gap:var(--bt-space-md);flex-wrap:wrap;
  padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  border-top:var(--bt-stroke-hairline) solid var(--bt-border-default);
  background:var(--bt-surface-raised);color:var(--bt-text-muted);
  font-size:var(--bt-type-body-sm-size)}

/* ── narrow: its own surface, not a squeeze (Page-Descriptions §13) ─────── */
.dbgnarrow{display:none}
@media (max-width:1100px){
  /* Every flex box above turns from "share a fixed viewport" into "be as tall
     as your content, up to a cap" — a pane that keeps `flex:1 1 0` inside an
     auto-height column resolves to zero and renders as an empty title bar,
     which is what a squeeze of the desktop layout actually looks like. */
  [data-register="debugger"] body{overflow:auto}
  [data-register="debugger"] .dbg{height:auto;min-height:100%}
  .dbgmain{flex:0 0 auto;flex-direction:column;height:auto;overflow:visible}
  .ln{flex:0 0 auto;height:auto}
  .ln.row{flex-direction:column}
  .pane,.ln.stack > .pane{flex:0 0 auto;height:auto}
  .panebody{flex:0 0 auto;height:auto;
    max-height:var(--bt-layout-code-max-height);overflow:auto}
  .dbgnarrow{display:block;flex:0 0 auto;
    padding:var(--bt-density-cell-y) var(--bt-layout-gutter);
    background:var(--bt-status-info-bg);color:var(--bt-status-info-fg);
    border-bottom:var(--bt-stroke-hairline) solid var(--bt-status-info-border);
    font-size:var(--bt-type-body-sm-size);line-height:var(--bt-type-body-sm-line)}
  /* Page-Descriptions §13: source, call trace and values, read-only. The
     controls and the event log are REMOVED rather than shrunk, and the banner
     above says so — an unannounced reduction is the §13 failure. */
  .p-controls{display:none}
  .p-eventlog,.stacktab.t-pane-eventlog{display:none}
  .stackpanel.def{display:flex}
  .dbgbar .btn,.dbgbar .btn.disabled{display:none}
}
@media (max-width:720px){
  .dbgbar{gap:var(--bt-space-sm);padding:0 var(--bt-space-md)}
  .dbgblock,.dbglang{display:none}
  .ctmod,.evdetail{display:none}
}
"""
