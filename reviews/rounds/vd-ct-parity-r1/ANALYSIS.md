# Round `vd-ct-parity-r1` — analysis, and why two findings are NOT defects

This round is **not in `reviews/ledger.json`**, and that is correct rather than
an oversight. `ingest-review.mjs` refused it:

    REFUSED — reviews of one triple disagree about what they looked at:
      debugger/wide/dark: 6 reviews over 2 different captures —
      ADV@02cbf7f736bc (STALE), L1@5d4cb33395fa, L3/L4/L5/L2@02cbf7f736bc (STALE)
    G2 requires the SAME image. Re-run the reviewers whose hash is stale.

`debugger/wide/dark` already carries a full six-lens round at an older capture,
and G2 requires all six reviewers to have seen byte-identical pixels. A single
lens cannot join an existing round. The report beside this file is kept as
evidence for whoever runs the next full round; it is not a ledger entry and
must not be hand-promoted into one.

## `debugger/wide/dark/L1/1` — tab idioms — NOT A DEFECT (parity)

> "Call Trace/Event Log still use a filled-box selected state and the
> frame-selector '3' button combines a filled box AND an underline. The screen
> still shows two coexisting selected-state treatments instead of one."

Two separate claims, and both resolve against the finding.

**The two tab treatments are CodeTracer's own.** Measured in the vendored
stylesheets at the pinned commit:

| surface | CodeTracer's rule | idiom |
| --- | --- | --- |
| pane tabs (`lm_active`, `golden_layout.styl`) | `background-color: colors-ui-surface-base-panel !important`, rounded top corners | filled box |
| design-system tabs (`.ct-tab[data-selected]`, `tab.styl`) | background + `border-bottom-color` | underline |

CodeTracer draws pane tabs and design-system tabs differently. Unifying them in
BlockTracer would make it MORE internally consistent than the thing it is being
graded against — a change that closes a finding while moving away from the
reference. The brief's §2 rule decides this: when internal consistency and the
application disagree in the debugger register, the application wins.

**The frame selector's "underline" is not a tab accent; it is a position
mark.** `components/debugger_css.nim` states the intent beside the rule:

> TWO marks, because there are two facts. `.frhere` is where the SESSION is and
> never moves. `.frdot` is which pass is on screen, and the rail moves it.
> Collapsing them would tell a reader who looked at pass 1 that the session had
> gone there. Both are shapes as well as colours, so neither depends on hue.

`.frhere` is a full-width bar at the segment's foot carrying
`--bt-mark-position`. Removing it so the control "reads as a pure control"
would delete the only signal of where the session actually is, which is a
correctness regression wearing the costume of a styling fix.

**Both sub-claims are honest readings of a screenshot.** They are wrong because
a screenshot cannot show that one bar is a semantic mark and that the other
idiom is inherited. That is a limit of the lens, not a reviewer error — and it
is the argument for giving the reviewer reference IMAGES, not only a reference
baseline of declared values.

## `debugger/wide/dark/L1/2` — hash truncated three ways — FIXED

Resolved in the same shape as `tx-detail/wide/light/L1/4`, whose resolution is
already in the ledger. Two causes here rather than one: `debugger.nim` passed
`10, 8` to `truncHash` (the explorer defect verbatim), and `session_view.nim`
defined a SECOND proc, `truncatedHash`, hardcoding 8/4 for the identity bar.
The first now takes the defaults; the second delegates.

Measured on the rebuilt page the way the precedent specified — distinct
0x-prefixed forms before: `…836b` (13), `f0…836b` (15), one of 21, full 42.
After: `0x1e82…836b` and the full value, beside the 10-character selector.
One truncation rule, not three.

## Still open

`L1/3` (FEE PAYER / TARGET hard-wrap) and `L1/4` (Values pane nesting has no
guide rule where Call Trace has one) are P3 and untouched.
