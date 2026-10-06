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

## `debugger/wide/dark/L1/3` — addresses print full-length — NOT A DEFECT

> "These addresses print full-length and hard-wrap ... rather than truncating
> with a copy affordance like every other identifier on the page."

Both halves are answered in `components/debugger.nim`, at the renderer:

    elif r.identifier:
      # Rendered in FULL — an address, a target, a cost pair, a decoded
      # argument — so one click selects the whole of it. `Copyable` lives
      # here rather than at either call site ...
      span(class = "identifier " & Copyable): text r.value

Full length is the decision, not an oversight: a selectable whole value is the
point. And the copy affordance the finding says is missing is already there —
the built page emits `<span class="identifier copyable">` on exactly these
rows. What remains is the narrower question of WHERE a too-long value wraps,
which is real but much smaller than the finding as written, and cannot be
fixed by truncating without reversing the decision above.

## `debugger/wide/dark/L1/4` — Values nesting has no guide rule — DESIGN CALL

The indent is deliberate and doubly anchored, per `debugger_css.nim`: it is
"the SAME ladder as the call trace, so one level of nesting means one indent
step in both panes", and the comment records that "the desktop app indents
state by a flat 16px per level and does not stop". So the two panes differ in
the GUIDE RULE, not the ladder, and the Values treatment is the one that
matches the reference application.

Adding a guide rule to Values is defensible, but it is a design decision
against the desktop app rather than a defect to close, so it is left for the
owner.

## What this round says about the REVIEW SETUP, which matters more

Of four findings: one was a real defect and is fixed; three were documented
decisions that a screenshot cannot reveal — an inherited idiom, a semantic
mark, and a deliberate full-length render. Every one of the three would have
made the product worse if "fixed", and two would have been outright
regressions.

The reviewer was not careless. It had the brief's expected-elements block and a
baseline of DECLARED VALUES, and neither carries intent. Three things would
change the hit rate:

1. **Reference images.** A reviewer that can see CodeTracer's own panes would
   not read an inherited idiom as an inconsistency. This is the gap the owner
   named at the outset and it is still the highest-value missing input.
2. **Rationale in the expected-elements block.** The block says WHAT must be on
   screen; it says nothing about which presentation choices are settled. The
   two marks on the flow rail, and full-length identifiers, are exactly the
   kind of settled choice a reviewer should be told not to re-litigate.
3. **A resolved-findings list in the prompt.** `tx-detail/wide/light/L1/4` was
   in the ledger as fixed; the same defect on another view was found again by a
   reviewer with no access to that history. That one was useful. The inverse —
   re-raising a closed WONTFIX — is pure cost.
