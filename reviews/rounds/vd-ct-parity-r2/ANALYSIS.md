# Round `vd-ct-parity-r2` — BlockTracer's debugger register against the CodeTracer IDE

Two review rounds against REAL reference images of CodeTracer's panels, captured
from its own Storybook at the pinned ref `af70456c` with its compiled theme and
its real fonts. Font loading was measured, not assumed: zero font 404s,
`document.fonts` reporting `SpaceGrotesk 400 loaded` / `FiraMono 400 loaded` /
`SpaceMono 400 loaded`, the woff2 fetched at 36,800 bytes, and SpaceGrotesk
measuring 611.30px against a 567.47px sans fallback on the same string.

## The defect both rounds were really measuring, now fixed

`.component-container` — CodeTracer's own panel rule — was vendored and served
but **emitted nowhere**. `grep -c component-container` over `debugger.nim` and
`pages/debug.nim` was 0, and the class never appeared in a built page. It was
dead CSS.

That is the tokens-versus-rules lesson one level deeper, and the reason the
first round reported the panes as reading "flatter" with headers flush on the
pane background: CodeTracer's panel typography and sizing were in the
stylesheet and applied to nothing.

Every pane body is now wrapped, 5 wrappers for 5 `.lm_content` panes on the
happy path, with `test_debug_route` unchanged at its pre-existing 33 failures
and an identical failing set.

ONE PANE IS DELIBERATELY NOT WRAPPED. `.nosession .lm_content{display:flex}`
with `.nostate{margin:auto}` centres the no-session notice only while `.nostate`
is a DIRECT flex child. Wrapping it moved the notice from centred to flush
top-left — measured, captures `d4a7db5ab3fc` → `78f3cf84dbe5` — which reads as
a debugger that failed to load. The correct fix is to give
`.nosession .component-container` its own `display:flex` rather than add the
class blind.

## The three ranked findings, resolved

### 1. Density — IMPROVED, and the fix is what moved it

Rows went from ~20–24px to ~23–26px, against CodeTracer's own monospace panels
at ~24–30px. That is `.component-container`'s `line-height: 1.5em` taking
effect, which is exactly what the change was supposed to do.

The honest limit, recorded by the reviewer rather than by us: there is no
CodeTracer SOURCE-CODE pane in the reference set, only Build and Terminal logs,
so this is the closest available proxy and not a like-for-like match.

### 2. Panel elevation — NOT A DEFECT. A comparison artifact.

The first round saw CodeTracer layering frame → panel → cards and BlockTracer
reading flat. Measured, the cards are not pane chrome:

| surface | background | radius | margin |
| --- | --- | --- | --- |
| `.lm_content` (panel) | `#282828` | 0.36em | — |
| `.component-wrapper` (the "card") | `#282828` | 0.25em | 0.5em |

The card is the SAME COLOUR as the panel; its apparent elevation is the
`margin: 0.5em` cutting an inset gutter. And more decisively,
**`.component-wrapper` is emitted nowhere in CodeTracer's own frontend** —
`grep -rn component-wrapper src/frontend --include='*.nim'` returns nothing. It
is dead CSS in CodeTracer too, so vendoring it would have copied a rule nothing
uses.

The cards actually visible in the Agent Activity reference come from that
panel's own content classes — `.agent-final-message` (4 markup references) and
`.agent-settings-panel` (1) — which is panel-specific design, not a universal
pane treatment. CodeTracer's flat log panels carry no card either.

So BlockTracer's flat data panes match CodeTracer's flat log panes, and the
first round compared them against its richest content panel. Vendoring
`agent_activity.styl` for this — 1,694 lines, for one unused rule — would have
imported a panel BlockTracer does not have.

### 3. Accent hue — DELIBERATE, recorded in the Bridge

CodeTracer's accent reads violet-leaning indigo; BlockTracer's a cooler blue.
That is the Bridge binding by ROLE across two different brand ramps, and it
says so per row — `=` marks an exact match, `->` a role binding:

    colors-ui-surface-action-primary        -> --bt-action-bg         # brand-500 -> brand-600
    colors-ui-surface-action-primary-hover  -> --bt-action-bg-hover   # brand-700 -> brand-500
    colors-ui-text-primary-active           -> --bt-accent-default    # brand-500 -> brand-400
    colors-ui-border-action                 -> --bt-border-accent     # brand-500 = brand-500

Only the border accent is exact; the three fills shift a ramp position
deliberately. Making the accents identical is a decision to change those
bindings, not a defect to close.

## Where that leaves the resemblance

Derived from CodeTracer's own rules and verified live rather than merely served:
the panel surface and typography (`.component-container`), the pane frame and
tab strip (`golden_layout`, `tab.styl`), row and table treatment
(`data_tables`), buttons, inputs, notifications and empty states.

Of the three ranked visual differences, one was a real defect and is fixed; two
are a deliberate binding and a comparison artifact.

**The remaining gap is not styling — it is DEPLOYMENT.** Production's live
stylesheet carries zero `.component-container`, so none of this is on
blocktracer.org yet. Until a rebuilt tree is published, a verification against
production measures the old build.
