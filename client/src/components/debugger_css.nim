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
.panedismiss{color:var(--bt-text-subtle);line-height:var(--bt-type-label-line);
  padding:0 var(--bt-space-3xs);border-radius:var(--bt-radius-xs);
  transition:color var(--bt-motion-fast) var(--bt-motion-ease)}
.panedismiss:hover{color:var(--bt-text-strong);background:var(--bt-surface-hover)}
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
.srcwrap{display:flex;flex-direction:column;min-height:0}
.srctabs{display:flex;gap:var(--bt-space-xs);flex-wrap:wrap;
  padding:var(--bt-space-3xs) var(--bt-density-cell-x);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  background:var(--bt-surface-sunken)}
.srctab{font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-label-size);color:var(--bt-text-subtle)}
.srctab.on{color:var(--bt-text-strong)}
.src{font-family:var(--bt-font-code),var(--bt-font-mono-fallback);
  font-size:var(--bt-type-code-size);line-height:var(--bt-type-code-line);
  color:var(--bt-text-code);background:var(--bt-surface-code);
  padding:var(--bt-space-2xs) 0;min-width:0}
.srcline{display:flex;align-items:flex-start;gap:var(--bt-space-xs);
  padding:0 var(--bt-density-cell-x);white-space:pre;
  border-left:var(--bt-stroke-thick) solid transparent}
.srcline .n{flex:0 0 var(--bt-space-2xl);text-align:right;
  color:var(--bt-text-subtle);font-variant-numeric:var(--bt-numeric-features);
  user-select:none}
.srcline .m{flex:0 0 var(--bt-space-md);color:var(--bt-text-subtle);
  text-align:center;user-select:none}
.srcline .t{font:inherit;color:inherit;white-space:pre;min-width:0}
.srcline.hit{background:var(--bt-surface-sunken)}
.srcline.hit .m{color:var(--bt-accent-subtle)}
.srcline.cur{background:var(--bt-surface-selected);
  border-left-color:var(--bt-accent-default)}
.srcline.cur .n,.srcline.cur .m{color:var(--bt-accent-default)}
.srcline.cur .t{color:var(--bt-text-strong)}
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
.ctunit{flex:0 0 auto;color:var(--bt-text-subtle);
  font-size:var(--bt-type-label-size);min-width:var(--bt-space-2xl)}
/* Depth is indentation, and the indentation ladder is the spacing scale. */
.ctrow.d0 .ctfn{padding-left:0}
.ctrow.d1 .ctfn{padding-left:var(--bt-space-md)}
.ctrow.d2 .ctfn{padding-left:var(--bt-space-xl)}
.ctrow.d3 .ctfn{padding-left:var(--bt-space-2xl)}
.ctrow.d4 .ctfn{padding-left:var(--bt-space-3xl)}
.ctrow.d5 .ctfn{padding-left:var(--bt-space-4xl)}
.ctfoot{border-bottom:0;color:var(--bt-text-subtle);
  font-size:var(--bt-type-label-size);justify-content:space-between}
.ctsort{color:var(--bt-text-link);text-decoration:underline;
  text-underline-offset:var(--bt-space-3xs)}

/* ── state ──────────────────────────────────────────────────────────────── */
.st{font-size:var(--bt-density-data-size)}
.strow{display:flex;align-items:baseline;gap:var(--bt-space-sm);
  padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle);
  border-left:var(--bt-stroke-thick) solid transparent}
.strow:hover{background:var(--bt-surface-hover)}
.strow.d1{padding-left:var(--bt-space-lg)}
.strow.d2{padding-left:var(--bt-space-2xl)}
.strow.chg{border-left-color:var(--bt-accent-default)}
.stname{flex:0 0 auto;font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  color:var(--bt-text-strong);word-break:break-all}
.sttype{flex:0 0 auto;color:var(--bt-text-subtle);
  font-size:var(--bt-type-label-size)}
.stval{flex:1 1 auto;min-width:0;text-align:right;
  font-family:var(--bt-font-mono),var(--bt-font-mono-fallback);
  font-variant-numeric:var(--bt-numeric-features);
  color:var(--bt-text-code);word-break:break-all}
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
.dctl .tick{flex:1 1 0;height:var(--bt-space-2xs);
  background:var(--bt-border-subtle);border-radius:var(--bt-radius-xs)}
.dctl .tick.on{background:var(--bt-accent-default);height:var(--bt-space-sm)}
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
.mdrevert{padding:0 var(--bt-density-cell-x) var(--bt-density-cell-y);
  color:var(--bt-status-danger-fg);font-size:var(--bt-type-body-sm-size)}
.mddl{display:grid;grid-template-columns:auto minmax(0,1fr);gap:0}
.mddl dt{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  font-size:var(--bt-type-label-size);font-weight:var(--bt-type-label-weight);
  letter-spacing:var(--bt-type-label-tracking);text-transform:uppercase;
  color:var(--bt-text-subtle);white-space:nowrap;
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
.mddl dd{padding:var(--bt-density-cell-y) var(--bt-density-cell-x);
  font-size:var(--bt-density-data-size);text-align:right;word-break:break-all;
  border-bottom:var(--bt-stroke-hairline) solid var(--bt-border-subtle)}
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
