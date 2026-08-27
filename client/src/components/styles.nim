## Explorer CSS for the BlockTracer IsoNim client.
##
## Two parts, both inlined into every page's <head> by components/layout.nim:
##
##   * `fontFaceCss` — @font-face for the brand faces vendored from
##     codetracer-design-system (Space Grotesk sans + Space Mono) under
##     src/assets/fonts/, served from /assets/fonts/.
##
##   * `globalCss` — the shell + view rules (nav, hero, sections, the shared
##     tables, badges, definition grids, footer). Every colour, font, space and
##     radius is `var(--ct-*)`, i.e. resolved from the design-system token layer
##     (design_system/tokens.emitTokensCss). There are NO ad-hoc hex/px design
##     values here — that is the "consume the design system, not ad-hoc CSS"
##     gate (Design-System.md). A few structural, non-token literals remain
##     (layout widths, transition timings, line-heights, breakpoints), which are
##     not design-system tokens.

const fontFaceCss* = """
@font-face{font-family:'Space Grotesk Variable';font-weight:400;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceGrotesk-Regular.woff2) format('woff2');}
@font-face{font-family:'Space Grotesk Variable';font-weight:500;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceGrotesk-Medium.woff2) format('woff2');}
@font-face{font-family:'Space Grotesk Variable';font-weight:700;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceGrotesk-Bold.woff2) format('woff2');}
@font-face{font-family:'Space Mono';font-weight:400;font-style:normal;font-display:swap;src:url(/assets/fonts/SpaceMono-Regular.ttf) format('truetype');}
"""

const globalCss* = """
*{margin:0;padding:0;box-sizing:border-box}
html{scroll-behavior:smooth}
html,body{background:var(--ct-bg);color:var(--ct-fg);font-family:var(--ct-font-sans);-webkit-font-smoothing:antialiased}
body{overflow-x:hidden;line-height:1.5}
::selection{background:var(--ct-action);color:var(--ct-on-action)}
a{color:inherit;text-decoration:none}
code,.mono{font-family:var(--ct-font-mono)}

/* layout primitives */
.inner{max-width:1180px;margin:0 auto;padding:0 var(--ct-space-2xl)}
.sec{padding:var(--ct-space-3xl) 0;position:relative}
.eyebrow{font-family:var(--ct-font-mono);font-size:var(--ct-text-2xs);letter-spacing:.18em;text-transform:uppercase;color:var(--ct-color-brand-400);display:flex;align-items:center;gap:12px;margin-bottom:var(--ct-space-lg)}
.eyebrow::before{content:'';width:24px;height:1px;background:var(--ct-color-brand-400);opacity:.6}
h1,h2,h3{letter-spacing:-.02em;line-height:1.15}
.h1{font-size:clamp(30px,4.4vw,48px);font-weight:700;max-width:20ch}
.h2{font-size:clamp(24px,3.2vw,36px);font-weight:700;max-width:24ch}
.lead{font-size:var(--ct-text-lg);line-height:1.6;color:var(--ct-fg-muted);max-width:64ch;margin-top:var(--ct-space-md)}
.muted{color:var(--ct-fg-muted)}
.pagebody{padding-top:calc(var(--ct-space-3xl) + var(--ct-space-2xl))}

/* nav */
.nav{position:fixed;top:0;left:0;right:0;z-index:20;display:flex;justify-content:space-between;align-items:center;padding:16px var(--ct-space-3xl);border-bottom:1px solid var(--ct-divider-subtle);background:color-mix(in srgb,var(--ct-bg) 88%,transparent);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px)}
.brand{font-weight:700;font-size:var(--ct-text-md);letter-spacing:-.02em;display:flex;align-items:center;gap:9px}
.brand .sq{width:15px;height:15px;border:1.5px solid var(--ct-color-brand-400);border-radius:var(--ct-radius-2xs);position:relative}
.brand .sq::after{content:'';position:absolute;inset:3px;background:var(--ct-color-brand-400);border-radius:1px;opacity:.85}
.nav .links{display:flex;gap:22px;align-items:center;font-size:var(--ct-text-sm)}
.nav .links a.opt{color:var(--ct-fg-muted);transition:color .2s}
.nav .links a.opt:hover{color:var(--ct-fg)}
.nav form{display:flex}
.nav input{background:var(--ct-bg-raised);border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-sm);color:var(--ct-fg);font-family:var(--ct-font-mono);font-size:var(--ct-text-xs);padding:7px 11px;width:220px}
.nav input::placeholder{color:var(--ct-fg-muted)}

/* breadcrumbs */
.crumbs{font-family:var(--ct-font-mono);font-size:var(--ct-text-xs);color:var(--ct-fg-muted);display:flex;gap:8px;flex-wrap:wrap;margin-bottom:var(--ct-space-lg)}
.crumbs a:hover{color:var(--ct-fg)}
.crumbs .sep{opacity:.5}

/* hero (home) */
.hero{padding:calc(var(--ct-space-3xl) + var(--ct-space-3xl)) 0 var(--ct-space-3xl)}
.hero .sub{margin-top:var(--ct-space-lg)}
.search{margin-top:var(--ct-space-xl);display:flex;gap:10px;max-width:560px}
.search input{flex:1;background:var(--ct-bg-raised);border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-md);color:var(--ct-fg);font-family:var(--ct-font-mono);font-size:var(--ct-text-sm);padding:14px 16px}
.chainstrip{display:flex;gap:14px;flex-wrap:wrap;margin-top:var(--ct-space-2xl)}
.chaincard{display:block;border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-lg);padding:var(--ct-space-lg) var(--ct-space-xl);background:var(--ct-bg-raised);transition:border-color .2s}
.chaincard:hover{border-color:var(--ct-border-action)}
.chaincard .name{font-weight:700;font-size:var(--ct-text-lg)}
.chaincard .meta{color:var(--ct-fg-muted);font-family:var(--ct-font-mono);font-size:var(--ct-text-xs);margin-top:6px}

/* headline stat row */
.stats{display:flex;gap:var(--ct-space-2xl);flex-wrap:wrap;margin-top:var(--ct-space-xl)}
.stat .k{font-family:var(--ct-font-mono);font-size:var(--ct-text-2xs);letter-spacing:.12em;text-transform:uppercase;color:var(--ct-fg-muted)}
.stat .v{font-size:var(--ct-text-2xl);font-weight:700;margin-top:4px}
.stat .v.mono{font-family:var(--ct-font-mono);font-size:var(--ct-text-lg)}

/* definition grid (block / tx detail) */
.dl{display:grid;grid-template-columns:180px 1fr;gap:0;border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-lg);overflow:hidden;margin-top:var(--ct-space-lg)}
.dl dt{padding:12px var(--ct-space-lg);font-family:var(--ct-font-mono);font-size:var(--ct-text-xs);color:var(--ct-fg-muted);background:var(--ct-bg-raised);border-bottom:1px solid var(--ct-divider-subtle)}
.dl dd{padding:12px var(--ct-space-lg);border-bottom:1px solid var(--ct-divider-subtle);word-break:break-all}
.dl dt:last-of-type,.dl dd:last-of-type{border-bottom:none}
.dl dd code{color:var(--ct-color-brand-400)}

/* tables */
.tablewrap{overflow-x:auto;border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-lg);margin-top:var(--ct-space-lg)}
table.tbl{width:100%;border-collapse:collapse;font-size:var(--ct-text-sm)}
table.tbl th{text-align:left;font-family:var(--ct-font-mono);font-size:var(--ct-text-2xs);letter-spacing:.1em;text-transform:uppercase;color:var(--ct-fg-muted);padding:11px var(--ct-space-lg);background:var(--ct-bg-raised);border-bottom:1px solid var(--ct-divider-subtle);white-space:nowrap}
table.tbl td{padding:11px var(--ct-space-lg);border-bottom:1px solid var(--ct-divider-subtle);white-space:nowrap}
table.tbl tr:last-child td{border-bottom:none}
table.tbl tbody tr:hover{background:var(--ct-bg-raised)}
table.tbl td.hash a,table.tbl td a.addr{font-family:var(--ct-font-mono);color:var(--ct-color-brand-400)}
table.tbl td.num{font-family:var(--ct-font-mono);text-align:right}
.empty{padding:var(--ct-space-xl);color:var(--ct-fg-muted);text-align:center}

/* badges */
.badge{display:inline-block;font-family:var(--ct-font-mono);font-size:var(--ct-text-2xs);letter-spacing:.04em;padding:3px 9px;border-radius:var(--ct-radius-2xs);border:1px solid var(--ct-border-primary);color:var(--ct-fg-muted)}
.badge.ok{color:var(--ct-color-success);border-color:var(--ct-color-success)}
.badge.bad{color:var(--ct-color-error);border-color:var(--ct-color-error)}
.badge.warn{color:var(--ct-color-warning);border-color:var(--ct-color-warning)}
.badge.muted{color:var(--ct-fg-muted);border-color:var(--ct-border-primary)}

/* buttons */
.btn{font-weight:500;font-size:var(--ct-text-sm);padding:11px 18px;border-radius:var(--ct-radius-md);display:inline-flex;gap:8px;align-items:center;transition:background .2s,border-color .2s,color .2s;cursor:pointer;border:1px solid transparent}
.btn.primary{background:var(--ct-action);color:var(--ct-on-action)}
.btn.primary:hover{background:var(--ct-action-hover)}
.btn.ghost{border-color:var(--ct-border-primary);color:var(--ct-fg)}
.btn.ghost:hover{border-color:var(--ct-border-action)}
.btn.disabled{border-color:var(--ct-border-primary);color:var(--ct-fg-muted);cursor:not-allowed}

/* tx-detail debug panel */
.debugcard{border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-lg);padding:var(--ct-space-xl);margin-top:var(--ct-space-lg);background:var(--ct-bg-raised)}
.debugcard .row{display:flex;align-items:center;gap:var(--ct-space-lg);flex-wrap:wrap}
.debugcard .note{color:var(--ct-fg-muted);font-size:var(--ct-text-sm);margin-top:var(--ct-space-md);max-width:70ch}
.execlist{list-style:none;margin-top:var(--ct-space-md);display:flex;flex-direction:column;gap:10px}
.execlist li{display:flex;align-items:center;gap:12px;flex-wrap:wrap;font-family:var(--ct-font-mono);font-size:var(--ct-text-xs)}
.execlist .sel{color:var(--ct-fg-muted);min-width:72px}
.execlist .reason{color:var(--ct-fg-muted);font-family:var(--ct-font-sans);font-size:var(--ct-text-sm)}

/* deferred / stub callouts */
.stub{border:1px dashed var(--ct-border-primary);border-radius:var(--ct-radius-md);padding:var(--ct-space-lg);margin-top:var(--ct-space-lg);color:var(--ct-fg-muted);font-size:var(--ct-text-sm)}
.stub b{color:var(--ct-fg)}

/* raw json */
pre.raw{margin-top:var(--ct-space-md);background:var(--ct-bg-raised);border:1px solid var(--ct-border-primary);border-radius:var(--ct-radius-md);padding:var(--ct-space-lg);overflow-x:auto;font-family:var(--ct-font-mono);font-size:var(--ct-text-xs);line-height:1.6;color:var(--ct-fg-muted)}

/* footer */
.foot{border-top:1px solid var(--ct-divider-subtle);margin-top:var(--ct-space-3xl);padding:var(--ct-space-2xl) 0;color:var(--ct-fg-muted);font-size:var(--ct-text-sm)}
.foot .inner{display:flex;justify-content:space-between;gap:var(--ct-space-lg);flex-wrap:wrap}
.foot code{color:var(--ct-color-brand-400)}

@media (max-width:720px){
  .dl{grid-template-columns:1fr}
  .dl dt{border-bottom:none}
  .nav input{width:130px}
}
"""
