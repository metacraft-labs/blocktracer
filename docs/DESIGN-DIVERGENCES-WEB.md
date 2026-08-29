# BlockTracer — Web-Lineage Design Divergences

> **Status:** live — maintained per [Design-System.md](../../codetracer-specs/BlockTracer/Design-System.md) §4.
> **Last updated:** 2026-08-28 (VD.2 Foundations Pass)
> **Enforced by:** `node tools/design/check-tokens.mjs` (checks B1–B4), which
> is a step of the `visual-design` CI job.
> **Token source:** [`client/src/design_system/web.tokens.json`](../client/src/design_system/web.tokens.json)

## 0. Why this file is here and not in `codetracer-design-system`

Design-System.md §3 places the web lineage's token file at
`codetracer-design-system/web/codetracer-web.tokens.json` and this document at
`codetracer-design-system/docs/DESIGN-DIVERGENCES-WEB.md`. **Both live in the
blocktracer repository instead, and that is itself a recorded divergence — the
one below numbered D-00.** The reason is mechanical rather than stylistic:

`flake.nix` pins `codetracer-design-system` as a **flake input**, and the build
reads it through `DESIGN_SYSTEM_SRC`, which resolves to a Nix store path. A file
added to a working checkout of the design system is invisible to the build until
that repository is committed, pushed and the flake pin bumped — three actions
outside this campaign, on a checkout shared with other agents' worktrees. Worse,
the §4.1 CI rule would then depend on a sibling checkout being present, and
would silently degrade to "not checked" on a runner that has only this
repository.

Keeping the web lineage in-repo makes the rule enforceable on a bare
`actions/checkout` and keeps **one** source of truth: `tokens.nim` and
`check-tokens.mjs` read the same JSON file, so the emitter and the checker
cannot drift apart. The convergence action is a file move plus a flake bump, and
is listed in §5.

## 1. The stance

Per the operator decision recorded in Design-System.md §1, the three lineages —
**product**, **docs**, **web** — are allowed to differ, and every difference is
recorded *as it is made* so that a later convergence pass is mechanical rather
than archaeological.

Every `--bt-*` variable BlockTracer ships carries a **binding kind**:

| Kind | Meaning |
| --- | --- |
| `bkToken` | `$value` is a `{ref}` into `codetracer-design-system`'s `brand/`, `alias/` or `mapped/` DTCG files, resolved at build time. No divergence. |
| `bkLiteral` | A value no lineage supplies. **Must** name a row in §3 via `$extensions["bt.divergence"]`, or the build itself raises — `tokens.nim` refuses to emit an untracked literal, before the linter ever runs. |

### 1.1 The CI rule

> Every `bkLiteral` binding must have a corresponding row in this document, and
> every row must correspond to at least one literal. A build that introduces an
> untracked literal fails.

Enforced in two places, deliberately:

1. **At build time.** `client/src/design_system/tokens.nim` raises on a
   `bkLiteral` with no `bt.divergence`, so an untracked literal never reaches a
   rendered page.
2. **At lint time.** `check-tokens.mjs` B1 fails on a literal whose row does not
   exist; **B2 fails on a row that no literal uses**, which is the direction
   that keeps this document from accumulating fiction; B3 fails when §4's
   generated table has drifted.

## 2. What VD.2 settled rather than diverged on

Design-System.md §4.2 flags two decisions as identity-level and expensive to
change late. Both are settled here **towards the brand**, so they are *not*
divergences and no row exists for them:

| Dimension | Decision | Binding |
| --- | --- | --- |
| **Mono face** | The brand face, `type.fontFamily.code-primary` (Space Mono). §4.2 calls the mono face "the product's texture" because BlockTracer is mostly hashes, addresses and code. A third mono across three lineages would make convergence meaningfully harder, and nothing about a hash argues for a different face than the desktop app uses. | `--bt-font-mono` = `{type.fontFamily.code-primary}` |
| **Accent / link** | The brand accent, `colors.brand.600` (indigo `#4f46e5`). The docs lineage already diverges to `#4168cc`; §4.2 says a third accent would be one too many, and the web lineage declines to be it. | `--bt-action-bg` = `{colors.brand.600}` |

Two further roles are separated *in name* while bound to the same value today,
so a later decision can move one without moving the other:

- `--bt-font-mono` (machine values: hashes, addresses, selectors, amounts) and
  `--bt-font-code` (source code) both resolve to `code-primary`. Design-System.md
  §7 requires source code to look like CodeTracer wherever it appears, including
  inside the explorer register; giving it its own role now means honouring that
  later is a one-line change rather than a search for every `pre`.

## 3. Divergences

Columns are those Design-System.md §4 specifies: a stable id, the dimension, the
web-lineage value, the product-lineage counterpart, and the decision phrased as
a question for the design-system authors.

<a id="d-00"></a>
<a id="d-01"></a>
<a id="d-02"></a>
<a id="d-03"></a>
<a id="d-04"></a>
<a id="d-05"></a>
<a id="d-06"></a>
<a id="d-07"></a>
<a id="d-08"></a>
<a id="d-09"></a>

| # | Dimension | Web-lineage value | Product-lineage token | Notes for the authors |
| --- | --- | --- | --- | --- |
| **D-00** | Location of the web lineage | `blocktracer/client/src/design_system/web.tokens.json` and this file | Design-System.md §3 specifies `codetracer-design-system/web/` and `.../docs/` | Should the web token file move into `codetracer-design-system` once the flake pin can be bumped in the same change, or does a consuming product owning its own semantic layer over the shared primitives turn out to be the better shape? *(This row is structural, not visual, and is the one row backed by no literal binding — see the note below the table.)* |
| **D-01** | Line-height model | Unitless ratios: `1.1` display, `1.15` h1, `1.25` h2, `1.3` h3, `1.6` body, `1.55` body-sm, `1.45` caption, `1.65` code, plus `1.6`/`1.35` as the two registers' density line-heights | `type.lineHeight.*` — px values (16, 20, 24, 28, 32, 36, 40, 48) paired to specific font sizes | The px pairs are correct for a fixed-size desktop UI and wrong for a page whose type must survive a 375px viewport and a user's browser zoom. Should the brand gain a unitless ratio ramp beside the px one, or is the px ramp intended to be authoritative and the web lineage wrong to leave it? |
| **D-02** | Letter spacing | `em`-relative tracking: `-0.022em` display through `-0.01em` h3; `0.14em` eyebrow; `0.06em` label; `-0.01em` identifier | `letterSpacing.0/1/2` = `-1`, `0`, `1` — px | Tracking that does not scale with the type size is wrong at both ends of a nine-step scale: −1px is invisible at 40px and brutal at 12px. Should `letterSpacing` become em-relative in the brand, or is it deliberately px for a fixed-size product UI? |
| **D-03** | Font weight encoding | CSS numeric weights: `400`, `500`, `700` | `type.fontWeight.{regular,medium,bold}` = the strings `"Regular"`, `"Medium"`, `"Bold"` | The brand encodes weight as a Figma style *name*, which no CSS `font-weight` can consume. Should the brand carry the numeric weight beside the name — it is the same information — or should each consumer keep its own mapping? Note the web lineage uses only 400/500/700 because those are the three weights vendored as `@font-face`; a token for 600 would render as a synthesised bold. |
| **D-04** | Motion durations and easing | `120ms` / `180ms` / `320ms`, `cubic-bezier(.2,0,.2,1)` | **No token.** No lineage defines motion. | Motion is a shared primitive by Design-System.md §2 — "motion durations … are common to both registers" — but there is nothing to share. VD.9 owns motion design; VD.2 fixes only the durations, so hover and active states across both registers move at one speed rather than three hand-written ones. Should these become brand tokens? |
| **D-05** | Elevation / shadow | Light: `0 1px 2px rgba(16,16,16,.06), 0 2px 8px rgba(16,16,16,.05)` and `0 8px 28px rgba(16,16,16,.14)`. Dark: `0 1px 2px rgba(0,0,0,.55)` and `0 10px 30px rgba(0,0,0,.62)`. | **No token.** | The product lineage separates surfaces with borders on a dark canvas, where shadows do almost nothing. On the web register's light canvas a card needs elevation to read as a card. Should the brand gain an elevation ramp, or is elevation legitimately a web-only concern? The two themes are not one shadow re-tinted — the dark pair is deliberately tighter and darker rather than a lightened copy. |
| **D-06** | Measure (line length) | `68ch` prose, `44ch` narrow, `22ch` title | **No token.** | VD.1 measured the transaction page's only running prose at ~130 characters per line, roughly twice a readable measure, because it filled the 1140px container. Measure is a typographic decision the same way a type scale is. Should it live in the brand's `type` group? |
| **D-07** | Page-grid geometry | `960px` container, `64px` nav height, `160px` label column, `260px` header search field, `700px` prose panel, `480px` code-block max height | **No token.** The brand has a spacing ramp but no layout geometry. | These numbers are what put the header and the body on ONE grid — VD.1 measured header content at x=24→1896 against a body column at x=390→1530. Is layout geometry per-product by nature, or should a shared `layout` group exist so the marketing site and the explorer agree on a container width? |
| **D-08** | Numeric feature settings | `tabular-nums lining-nums` | **No token.** | Rubric A5 requires tabular figures in numeric columns, and this product is mostly digits. OpenType feature selection is a typographic property with no representation in any lineage. Should it become a `type` token, given the desktop app's cost columns have the same requirement? |
| **D-09** | Font fallback stacks | `ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif` and `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace` | **No token.** The brand names one family per role. | The desktop app ships its fonts and never falls back; a web page served to an arbitrary browser must. Should fallbacks be part of the brand's font tokens, or is a fallback stack inherently a delivery-channel concern? |

**One row is intentionally not backed by a literal: D-00**, which records where
this lineage lives rather than what it renders. It is named in
`check-tokens.mjs`'s `STRUCTURAL_ROWS` set — **enumerated, not pattern-matched**,
so a second structural row is a deliberate edit to the checker rather than a
regex that quietly stops enforcing anything. B2 fails in both directions: an
ordinary row with no literal behind it is an orphan, and a *structural* row that
acquires a literal is misfiled.

### 3.1 Near-matches

Aligned enough to snap at any time with no visible change. These are *not*
divergences; they are recorded so a convergence pass does not have to
re-derive them.

| Dimension | Web-lineage binding | Note |
| --- | --- | --- |
| Light canvas | `--bt-surface-canvas` = `{colors.graphite.50}` = `#ececeb` | The docs lineage chose warm `#f0eeea`; the brand's `graphite.50` is `#ececeb`. The web lineage takes the brand value, so web and product agree and only docs differs. Snapping docs to `graphite.50` would unify all three with a change of roughly 1% lightness. |
| Accent | `--bt-action-bg` = `{colors.brand.600}` | Identical to the product lineage. Docs diverges to `#4168cc`; web does not. |
| Spacing ramp | `--bt-space-*` = `{scale.200 … scale.1300}` | Every step is a brand `scale.*` primitive: 2·4·8·12·16·24·32·48·60·100. The web lineage adds no new step; it only *names* three of them as rhythm roles (§3.2). |
| Radii | `--bt-radius-*` = `{border.border radius.*}` | Straight from the brand ramp. |
| Focus ring | `--bt-focus-ring` = `{colors.ui.border.focus}` (light), `{colors.information.400}` (dark) | The light binding is the mapped token exactly. The dark binding steps one rung lighter because `blue.500` on a `#101010` canvas is a dim ring; both are brand primitives. |
| Status colours | `--bt-status-*` = `{colors.{success,error,warning,information}.*}` | Every status role is a brand primitive; the web lineage only chooses which rung of each ramp reads correctly on a light canvas versus a dark one. |
| Type sizes | `--bt-type-*-size` = `{type.fontSize.*}` | The nine-step brand ramp, unchanged. Only the *roles* mapped onto it are new. |

### 3.2 Rhythm roles — a naming layer, not a divergence

VD.1's measured finding was that one spacing step did two jobs: the pitch
between two rows inside a card (49–50px) equalled the gap between two sections
(49.0px), so proximity carried no grouping information anywhere on the page. The
root cause was that the scale ran 4·6·8·10·12·14·16·20·24 and stopped — it had no
section-level step at all.

The fix is not a new value; it is **named roles** drawn from the brand ramp,
with a separation the linter enforces:

| Rung | Binding | Resolves to | Job |
| --- | --- | --- | --- |
| `2 × --bt-density-cell-y` | `{scale.300}` explorer, `{scale.250}` debugger | 12px / 8px | The gap between two adjacent rows of a table or definition grid: two cell paddings meeting at a hairline. Per **register**, which is why the padding it is built from is a density token and not a rhythm one. |
| `--bt-rhythm-stack` | `{scale.650}` | 24px | Between sibling elements inside one group. |
| `--bt-rhythm-group` | `{scale.950}` | 48px | Between groups inside one section. |
| `--bt-rhythm-section` | `{scale.1300}` | 100px | Between two top-level sections. |

`check-tokens.mjs` C3 resolves these to numbers through the design system and
fails if any rung is less than **1.75×** the one below it, **in both
registers**. That is the property the page actually needs — that a section
boundary can never again be mistaken for a row gap — expressed as something a
script decides rather than a thing someone remembers.

#### Why the bottom rung is a density token and not `--bt-rhythm-row`

VD.2 shipped a fourth role, `--bt-rhythm-row` = `{scale.450}` = 12px, and C3
ranked it as the bottom rung. **No rule in `styles.nim` ever referenced it.**
Table cells and definition-grid cells take their vertical padding from
`--bt-density-cell-y`, because row density is a property of the *register*
(Design-System.md §2) and a register-independent rhythm role cannot express it.
So C3 was ranking a value that was emitted into every page's `<style>` block and
read by nothing — a separation check passing on a number no page could render.

VD.3 deleted the dead token and put the live one in its place, which makes the
ladder **register-aware**: both registers are ranked, because a rhythm that
holds in the explorer and collapses in the debugger is the "two component sets"
failure §2 forbids, and C3 could not previously see it.

#### Why the rung is the row-to-row GAP and not the row padding

VD.3's first attempt ranked `cell-y` — the **padding** — against the margins
above it, printed the row-to-row **gap** that padding produces beside the
verdict, and did not gate on it, on the grounds that adjacent rows carry a
hairline rule as well as space and that whether the 1.75× bar should apply
across a ruled boundary is a design decision a linter may not make alone. VD.3's
review round overruled that, on three grounds:

* **A ladder only means anything if every rung is the same kind of quantity.**
  `cell-y` is a padding; stack, group and section are gaps. Two paddings meet at
  every row boundary, so the like-for-like number is `2 × cell-y`. Gating a
  half-quantity against a full one made the bottom ratio read 3.00× when the
  real separation was 1.50×.
* **It let the founding defect straight back in.** With `cell-y` at
  `{scale.450}` = 12px — an ordinary step of the brand ramp, one token away —
  the row-to-row gap is 24px, **exactly** the 24px stack rung. C3 printed
  `1.00x under stack` and **passed**, and the whole checker exited 0. That is
  verbatim the VD.1 defect this ladder exists to prevent: one spacing step doing
  two jobs, so proximity carries no grouping information anywhere.
* **The hairline argument is not applied anywhere else.** `.sec-title.next`
  puts a hairline rule across the *largest* gap in the system. This stylesheet
  does not hold "a rule substitutes for space" as a principle; it was invoked in
  the one place the number failed. (The supporting evidence was also uncitable:
  "round 3 reported one scale, correct proximity" resolves to a sentence in
  `reviews/ledger.json`'s free-text `_comment` describing a round the ledger
  itself says is **not recorded** — so check B4, added in the same branch to stop
  comments reading as evidence, cannot reach it.)

The gate costs **one token**: explorer `cell-y` moves `{scale.350}` → `{scale.300}`,
8px → 6px, so the gap is 12px and the stack rung clears it by 2.00×. The stack,
group and section values the review rounds actually measured and approved are
untouched, the explorer stays distinct from the debugger (6px against 4px), and
the change moves a data-dense explorer table in the direction it wants to go.

What C3 still does **not** rank, and says so on every run, is the row **pitch** —
padding + line box + hairline. A pitch is not comparable to a gap, and it was
comparing one to the other (49px pitch against a 49px section gap) that produced
VD.1's original finding in the first place.

### 3.3 Non-visual divergences

Design-System.md §5 requires the same discipline for two things that are not
colours.

| Kind | Status at VD.2 |
| --- | --- |
| **Keyboard model** | Nothing to record. The explorer register has no shortcuts, and `/{chain}/tx/{hash}/debug` is not served, so no debugger shortcut exists to differ from `Keyboard-Shortcuts-System.md`. This row exists so its emptiness is a statement rather than an omission. |
| **Terminology** | Nothing new to record at VD.2. The explorer says "transaction" and the debugger says "trace" for the same object, which Design-System.md §5 already names as the standing case. VD.2 changed no user-facing term. |

## 4. Implemented bindings

Every `--bt-*` variable the product emits, with its binding kind and its brand
counterpart. **Generated** — regenerate with
`node tools/design/check-tokens.mjs --write-bindings`, and check B3 fails if it
has drifted.

<!-- BEGIN GENERATED: implemented bindings -->

| `--bt-*` variable | Binding | Value / brand counterpart | Divergence |
| --- | --- | --- | --- |
| **`base`** | | | |
| `--bt-focus-offset` | bkToken | `{scale.200}` | — |
| `--bt-focus-width` | bkToken | `{border.border width.thick}` | — |
| `--bt-font-code` | bkToken | `{type.fontFamily.code-primary}` | — |
| `--bt-font-mono` | bkToken | `{type.fontFamily.code-primary}` | — |
| `--bt-font-mono-fallback` | bkLiteral | `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace` | [D-09](#d-09) |
| `--bt-font-sans` | bkToken | `{type.fontFamily.ui-primary}` | — |
| `--bt-font-sans-fallback` | bkLiteral | `ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif` | [D-09](#d-09) |
| `--bt-layout-code-max-height` | bkLiteral | `480px` | [D-07](#d-07) |
| `--bt-layout-container` | bkLiteral | `960px` | [D-07](#d-07) |
| `--bt-layout-gutter` | bkToken | `{scale.650}` | — |
| `--bt-layout-label-column` | bkLiteral | `160px` | [D-07](#d-07) |
| `--bt-layout-nav-height` | bkLiteral | `64px` | [D-07](#d-07) |
| `--bt-layout-prose` | bkLiteral | `700px` | [D-07](#d-07) |
| `--bt-layout-search` | bkLiteral | `260px` | [D-07](#d-07) |
| `--bt-measure-narrow` | bkLiteral | `44ch` | [D-06](#d-06) |
| `--bt-measure-prose` | bkLiteral | `68ch` | [D-06](#d-06) |
| `--bt-measure-title` | bkLiteral | `22ch` | [D-06](#d-06) |
| `--bt-motion-base` | bkLiteral | `180ms` | [D-04](#d-04) |
| `--bt-motion-ease` | bkLiteral | `cubic-bezier(.2,0,.2,1)` | [D-04](#d-04) |
| `--bt-motion-fast` | bkLiteral | `120ms` | [D-04](#d-04) |
| `--bt-motion-slow` | bkLiteral | `320ms` | [D-04](#d-04) |
| `--bt-numeric-features` | bkLiteral | `tabular-nums lining-nums` | [D-08](#d-08) |
| `--bt-radius-full` | bkToken | `{border.border radius.full}` | — |
| `--bt-radius-lg` | bkToken | `{border.border radius.lg}` | — |
| `--bt-radius-md` | bkToken | `{border.border radius.sm}` | — |
| `--bt-radius-sm` | bkToken | `{border.border radius.xs}` | — |
| `--bt-radius-xl` | bkToken | `{border.border radius.2xl}` | — |
| `--bt-radius-xs` | bkToken | `{border.border radius.2xs}` | — |
| `--bt-rhythm-group` | bkToken | `{scale.950}` | — |
| `--bt-rhythm-section` | bkToken | `{scale.1300}` | — |
| `--bt-rhythm-stack` | bkToken | `{scale.650}` | — |
| `--bt-space-2xl` | bkToken | `{scale.950}` | — |
| `--bt-space-2xs` | bkToken | `{scale.250}` | — |
| `--bt-space-3xl` | bkToken | `{scale.1200}` | — |
| `--bt-space-3xs` | bkToken | `{scale.200}` | — |
| `--bt-space-4xl` | bkToken | `{scale.1300}` | — |
| `--bt-space-lg` | bkToken | `{scale.650}` | — |
| `--bt-space-md` | bkToken | `{scale.550}` | — |
| `--bt-space-sm` | bkToken | `{scale.450}` | — |
| `--bt-space-xl` | bkToken | `{scale.750}` | — |
| `--bt-space-xs` | bkToken | `{scale.350}` | — |
| `--bt-stroke-hairline` | bkToken | `{border.border width.deafult}` | — |
| `--bt-stroke-thick` | bkToken | `{border.border width.thick}` | — |
| `--bt-type-body-line` | bkLiteral | `1.6` | [D-01](#d-01) |
| `--bt-type-body-size` | bkToken | `{type.fontSize.md}` | — |
| `--bt-type-body-sm-line` | bkLiteral | `1.55` | [D-01](#d-01) |
| `--bt-type-body-sm-size` | bkToken | `{type.fontSize.sm}` | — |
| `--bt-type-body-sm-weight` | bkLiteral | `400` | [D-03](#d-03) |
| `--bt-type-body-weight` | bkLiteral | `400` | [D-03](#d-03) |
| `--bt-type-caption-line` | bkLiteral | `1.45` | [D-01](#d-01) |
| `--bt-type-caption-size` | bkToken | `{type.fontSize.xs}` | — |
| `--bt-type-caption-weight` | bkLiteral | `400` | [D-03](#d-03) |
| `--bt-type-code-line` | bkLiteral | `1.65` | [D-01](#d-01) |
| `--bt-type-code-size` | bkToken | `{type.fontSize.sm}` | — |
| `--bt-type-code-weight` | bkLiteral | `400` | [D-03](#d-03) |
| `--bt-type-display-line` | bkLiteral | `1.1` | [D-01](#d-01) |
| `--bt-type-display-size` | bkToken | `{type.fontSize.4xl}` | — |
| `--bt-type-display-tracking` | bkLiteral | `-0.022em` | [D-02](#d-02) |
| `--bt-type-display-weight` | bkLiteral | `700` | [D-03](#d-03) |
| `--bt-type-eyebrow-line` | bkLiteral | `1.3` | [D-01](#d-01) |
| `--bt-type-eyebrow-size` | bkToken | `{type.fontSize.xs}` | — |
| `--bt-type-eyebrow-tracking` | bkLiteral | `0.14em` | [D-02](#d-02) |
| `--bt-type-eyebrow-weight` | bkLiteral | `700` | [D-03](#d-03) |
| `--bt-type-h1-line` | bkLiteral | `1.15` | [D-01](#d-01) |
| `--bt-type-h1-size` | bkToken | `{type.fontSize.3xl}` | — |
| `--bt-type-h1-tracking` | bkLiteral | `-0.02em` | [D-02](#d-02) |
| `--bt-type-h1-weight` | bkLiteral | `700` | [D-03](#d-03) |
| `--bt-type-h2-line` | bkLiteral | `1.25` | [D-01](#d-01) |
| `--bt-type-h2-size` | bkToken | `{type.fontSize.xl}` | — |
| `--bt-type-h2-tracking` | bkLiteral | `-0.015em` | [D-02](#d-02) |
| `--bt-type-h2-weight` | bkLiteral | `700` | [D-03](#d-03) |
| `--bt-type-h3-line` | bkLiteral | `1.3` | [D-01](#d-01) |
| `--bt-type-h3-size` | bkToken | `{type.fontSize.lg}` | — |
| `--bt-type-h3-tracking` | bkLiteral | `-0.01em` | [D-02](#d-02) |
| `--bt-type-h3-weight` | bkLiteral | `700` | [D-03](#d-03) |
| `--bt-type-identifier-lead-line` | bkLiteral | `1.4` | [D-01](#d-01) |
| `--bt-type-identifier-lead-size` | bkToken | `{type.fontSize.md}` | — |
| `--bt-type-identifier-lead-tracking` | bkLiteral | `-0.015em` | [D-02](#d-02) |
| `--bt-type-identifier-lead-weight` | bkLiteral | `400` | [D-03](#d-03) |
| `--bt-type-identifier-line` | bkLiteral | `1.5` | [D-01](#d-01) |
| `--bt-type-identifier-size` | bkToken | `{type.fontSize.sm}` | — |
| `--bt-type-identifier-tracking` | bkLiteral | `-0.01em` | [D-02](#d-02) |
| `--bt-type-identifier-weight` | bkLiteral | `400` | [D-03](#d-03) |
| `--bt-type-label-line` | bkLiteral | `1.4` | [D-01](#d-01) |
| `--bt-type-label-size` | bkToken | `{type.fontSize.xs}` | — |
| `--bt-type-label-tracking` | bkLiteral | `0.06em` | [D-02](#d-02) |
| `--bt-type-label-weight` | bkLiteral | `500` | [D-03](#d-03) |
| `--bt-type-numeric-line` | bkLiteral | `1.5` | [D-01](#d-01) |
| `--bt-type-numeric-size` | bkToken | `{type.fontSize.sm}` | — |
| `--bt-type-numeric-weight` | bkLiteral | `400` | [D-03](#d-03) |
| **`theme.light`** | | | |
| `--bt-accent-default` | bkToken | `{colors.brand.600}` | — |
| `--bt-accent-subtle` | bkToken | `{colors.brand.500}` | — |
| `--bt-action-bg` | bkToken | `{colors.brand.600}` | — |
| `--bt-action-bg-active` | bkToken | `{colors.brand.800}` | — |
| `--bt-action-bg-hover` | bkToken | `{colors.brand.700}` | — |
| `--bt-action-disabled-bg` | bkToken | `{colors.neutral.100}` | — |
| `--bt-action-disabled-border` | bkToken | `{colors.neutral.150}` | — |
| `--bt-action-disabled-fg` | bkToken | `{colors.neutral.450}` | — |
| `--bt-action-fg` | bkToken | `{colors.base.white}` | — |
| `--bt-action-ghost-bg` | bkToken | `{colors.base.white}` | — |
| `--bt-action-ghost-bg-active` | bkToken | `{colors.neutral.100}` | — |
| `--bt-action-ghost-bg-hover` | bkToken | `{colors.neutral.50}` | — |
| `--bt-action-ghost-border` | bkToken | `{colors.neutral.250}` | — |
| `--bt-action-ghost-border-hover` | bkToken | `{colors.brand.600}` | — |
| `--bt-action-ghost-fg` | bkToken | `{colors.neutral.1000}` | — |
| `--bt-border-accent` | bkToken | `{colors.brand.600}` | — |
| `--bt-border-default` | bkToken | `{colors.neutral.250}` | — |
| `--bt-border-strong` | bkToken | `{colors.neutral.350}` | — |
| `--bt-border-subtle` | bkToken | `{colors.neutral.150}` | — |
| `--bt-elevation-overlay` | bkLiteral | `0 8px 28px rgba(16,16,16,.14)` | [D-05](#d-05) |
| `--bt-elevation-raised` | bkLiteral | `0 1px 2px rgba(16,16,16,.06), 0 2px 8px rgba(16,16,16,.05)` | [D-05](#d-05) |
| `--bt-focus-ring` | bkToken | `{colors.ui.border.focus}` | — |
| `--bt-mark-changed` | bkToken | `{colors.yellow.800}` | — |
| `--bt-mark-executable` | bkToken | `{colors.cyan.700}` | — |
| `--bt-mark-position` | bkToken | `{colors.cyan.900}` | — |
| `--bt-mark-position-surface` | bkToken | `{colors.cyan.200}` | — |
| `--bt-mark-track` | bkToken | `{colors.neutral.300}` | — |
| `--bt-mark-track-elapsed` | bkToken | `{colors.cyan.800}` | — |
| `--bt-mark-view` | bkToken | `{colors.neutral.1000}` | — |
| `--bt-status-danger-bg` | bkToken | `{colors.error.100}` | — |
| `--bt-status-danger-border` | bkToken | `{colors.error.600}` | — |
| `--bt-status-danger-fg` | bkToken | `{colors.error.800}` | — |
| `--bt-status-info-bg` | bkToken | `{colors.information.100}` | — |
| `--bt-status-info-border` | bkToken | `{colors.information.600}` | — |
| `--bt-status-info-fg` | bkToken | `{colors.information.800}` | — |
| `--bt-status-neutral-bg` | bkToken | `{colors.neutral.50}` | — |
| `--bt-status-neutral-border` | bkToken | `{colors.neutral.150}` | — |
| `--bt-status-neutral-fg` | bkToken | `{colors.neutral.450}` | — |
| `--bt-status-success-bg` | bkToken | `{colors.success.100}` | — |
| `--bt-status-success-border` | bkToken | `{colors.success.600}` | — |
| `--bt-status-success-fg` | bkToken | `{colors.success.800}` | — |
| `--bt-status-warning-bg` | bkToken | `{colors.warning.100}` | — |
| `--bt-status-warning-border` | bkToken | `{colors.warning.600}` | — |
| `--bt-status-warning-fg` | bkToken | `{colors.warning.800}` | — |
| `--bt-surface-canvas` | bkToken | `{colors.graphite.50}` | — |
| `--bt-surface-code` | bkToken | `{colors.graphite.50}` | — |
| `--bt-surface-hover` | bkToken | `{colors.neutral.50}` | — |
| `--bt-surface-overlay` | bkToken | `{colors.base.white}` | — |
| `--bt-surface-raised` | bkToken | `{colors.base.white}` | — |
| `--bt-surface-selected` | bkToken | `{colors.brand.100}` | — |
| `--bt-surface-sunken` | bkToken | `{colors.neutral.100}` | — |
| `--bt-syntax-comment` | bkToken | `{colors.green.800}` | — |
| `--bt-syntax-function` | bkToken | `{colors.yellow.900}` | — |
| `--bt-syntax-keyword` | bkToken | `{colors.blue.700}` | — |
| `--bt-syntax-number` | bkToken | `{colors.violet.700}` | — |
| `--bt-syntax-plain` | bkToken | `{colors.neutral.800}` | — |
| `--bt-syntax-punctuation` | bkToken | `{colors.neutral.500}` | — |
| `--bt-syntax-string` | bkToken | `{colors.orange.800}` | — |
| `--bt-syntax-type` | bkToken | `{colors.cyan.800}` | — |
| `--bt-text-code` | bkToken | `{colors.neutral.800}` | — |
| `--bt-text-default` | bkToken | `{colors.neutral.800}` | — |
| `--bt-text-disabled` | bkToken | `{colors.neutral.400}` | — |
| `--bt-text-link` | bkToken | `{colors.brand.600}` | — |
| `--bt-text-link-hover` | bkToken | `{colors.brand.700}` | — |
| `--bt-text-muted` | bkToken | `{colors.neutral.500}` | — |
| `--bt-text-on-accent` | bkToken | `{colors.base.white}` | — |
| `--bt-text-strong` | bkToken | `{colors.neutral.1000}` | — |
| `--bt-text-subtle` | bkToken | `{colors.neutral.450}` | — |
| **`theme.dark`** | | | |
| `--bt-accent-default` | bkToken | `{colors.brand.400}` | — |
| `--bt-accent-subtle` | bkToken | `{colors.brand.300}` | — |
| `--bt-action-bg` | bkToken | `{colors.brand.600}` | — |
| `--bt-action-bg-active` | bkToken | `{colors.brand.400}` | — |
| `--bt-action-bg-hover` | bkToken | `{colors.brand.500}` | — |
| `--bt-action-disabled-bg` | bkToken | `{colors.neutral.850}` | — |
| `--bt-action-disabled-border` | bkToken | `{colors.neutral.700}` | — |
| `--bt-action-disabled-fg` | bkToken | `{colors.neutral.300}` | — |
| `--bt-action-fg` | bkToken | `{colors.base.white}` | — |
| `--bt-action-ghost-bg` | bkToken | `{colors.neutral.900}` | — |
| `--bt-action-ghost-bg-active` | bkToken | `{colors.neutral.800}` | — |
| `--bt-action-ghost-bg-hover` | bkToken | `{colors.neutral.850}` | — |
| `--bt-action-ghost-border` | bkToken | `{colors.neutral.450}` | — |
| `--bt-action-ghost-border-hover` | bkToken | `{colors.brand.500}` | — |
| `--bt-action-ghost-fg` | bkToken | `{colors.neutral.50}` | — |
| `--bt-border-accent` | bkToken | `{colors.brand.500}` | — |
| `--bt-border-default` | bkToken | `{colors.neutral.450}` | — |
| `--bt-border-strong` | bkToken | `{colors.neutral.400}` | — |
| `--bt-border-subtle` | bkToken | `{colors.neutral.700}` | — |
| `--bt-elevation-overlay` | bkLiteral | `0 10px 30px rgba(0,0,0,.62)` | [D-05](#d-05) |
| `--bt-elevation-raised` | bkLiteral | `0 1px 2px rgba(0,0,0,.55)` | [D-05](#d-05) |
| `--bt-focus-ring` | bkToken | `{colors.information.400}` | — |
| `--bt-mark-changed` | bkToken | `{colors.amber.300}` | — |
| `--bt-mark-executable` | bkToken | `{colors.cyan.500}` | — |
| `--bt-mark-position` | bkToken | `{colors.cyan.300}` | — |
| `--bt-mark-position-surface` | bkToken | `{colors.slate.700}` | — |
| `--bt-mark-track` | bkToken | `{colors.neutral.400}` | — |
| `--bt-mark-track-elapsed` | bkToken | `{colors.cyan.400}` | — |
| `--bt-mark-view` | bkToken | `{colors.neutral.50}` | — |
| `--bt-status-danger-bg` | bkToken | `{colors.neutral.850}` | — |
| `--bt-status-danger-border` | bkToken | `{colors.error.600}` | — |
| `--bt-status-danger-fg` | bkToken | `{colors.error.400}` | — |
| `--bt-status-info-bg` | bkToken | `{colors.neutral.850}` | — |
| `--bt-status-info-border` | bkToken | `{colors.information.600}` | — |
| `--bt-status-info-fg` | bkToken | `{colors.information.400}` | — |
| `--bt-status-neutral-bg` | bkToken | `{colors.neutral.850}` | — |
| `--bt-status-neutral-border` | bkToken | `{colors.neutral.600}` | — |
| `--bt-status-neutral-fg` | bkToken | `{colors.neutral.300}` | — |
| `--bt-status-success-bg` | bkToken | `{colors.neutral.850}` | — |
| `--bt-status-success-border` | bkToken | `{colors.success.600}` | — |
| `--bt-status-success-fg` | bkToken | `{colors.success.400}` | — |
| `--bt-status-warning-bg` | bkToken | `{colors.neutral.850}` | — |
| `--bt-status-warning-border` | bkToken | `{colors.warning.600}` | — |
| `--bt-status-warning-fg` | bkToken | `{colors.warning.400}` | — |
| `--bt-surface-canvas` | bkToken | `{colors.base.black}` | — |
| `--bt-surface-code` | bkToken | `{colors.base.black}` | — |
| `--bt-surface-hover` | bkToken | `{colors.neutral.650}` | — |
| `--bt-surface-overlay` | bkToken | `{colors.neutral.850}` | — |
| `--bt-surface-raised` | bkToken | `{colors.neutral.900}` | — |
| `--bt-surface-selected` | bkToken | `{colors.brand.900}` | — |
| `--bt-surface-sunken` | bkToken | `{colors.neutral.700}` | — |
| `--bt-syntax-comment` | bkToken | `{colors.green.500}` | — |
| `--bt-syntax-function` | bkToken | `{colors.amber.400}` | — |
| `--bt-syntax-keyword` | bkToken | `{colors.blue.300}` | — |
| `--bt-syntax-number` | bkToken | `{colors.violet.300}` | — |
| `--bt-syntax-plain` | bkToken | `{colors.editor.syntax.primary}` | — |
| `--bt-syntax-punctuation` | bkToken | `{colors.editor.syntax.secondary}` | — |
| `--bt-syntax-string` | bkToken | `{colors.orange.300}` | — |
| `--bt-syntax-type` | bkToken | `{colors.cyan.300}` | — |
| `--bt-text-code` | bkToken | `{colors.neutral.100}` | — |
| `--bt-text-default` | bkToken | `{colors.neutral.100}` | — |
| `--bt-text-disabled` | bkToken | `{colors.neutral.400}` | — |
| `--bt-text-link` | bkToken | `{colors.brand.400}` | — |
| `--bt-text-link-hover` | bkToken | `{colors.brand.300}` | — |
| `--bt-text-muted` | bkToken | `{colors.neutral.250}` | — |
| `--bt-text-on-accent` | bkToken | `{colors.base.white}` | — |
| `--bt-text-strong` | bkToken | `{colors.neutral.50}` | — |
| `--bt-text-subtle` | bkToken | `{colors.neutral.300}` | — |
| **`register.explorer`** | | | |
| `--bt-density-body-size` | bkToken | `{type.fontSize.md}` | — |
| `--bt-density-card-pad` | bkToken | `{scale.750}` | — |
| `--bt-density-cell-x` | bkToken | `{scale.650}` | — |
| `--bt-density-cell-y` | bkToken | `{scale.300}` | — |
| `--bt-density-control-x` | bkToken | `{scale.650}` | — |
| `--bt-density-control-y` | bkToken | `{scale.450}` | — |
| `--bt-density-data-size` | bkToken | `{type.fontSize.sm}` | — |
| `--bt-density-line` | bkLiteral | `1.6` | [D-01](#d-01) |
| **`register.debugger`** | | | |
| `--bt-density-body-size` | bkToken | `{type.fontSize.sm}` | — |
| `--bt-density-card-pad` | bkToken | `{scale.450}` | — |
| `--bt-density-cell-x` | bkToken | `{scale.350}` | — |
| `--bt-density-cell-y` | bkToken | `{scale.250}` | — |
| `--bt-density-control-x` | bkToken | `{scale.450}` | — |
| `--bt-density-control-y` | bkToken | `{scale.250}` | — |
| `--bt-density-data-size` | bkToken | `{type.fontSize.xs}` | — |
| `--bt-density-line` | bkLiteral | `1.35` | [D-01](#d-01) |

<!-- END GENERATED: implemented bindings -->

## 5. Convergence actions

In the order Design-System.md §8 prescribes: decide, then flip, then snap, then
merge.

1. **D-00** — move `web.tokens.json` into `codetracer-design-system/web/` and
   this file into its `docs/`, in a single change that also bumps the flake pin.
   Until then, keep the two in this repository: a half-moved lineage is worse
   than either end state.
2. **D-01 / D-02 / D-03** — these three are one decision, not three: whether the
   brand's `type` group is a Figma export or a cross-platform contract. If it
   becomes a contract, all three flip mechanically and thirty-odd literals
   become token bindings in one pass.
3. **D-04 / D-05 / D-06 / D-08** — four groups the brand simply does not have.
   Each is a question of scope, and none blocks anything today.
4. **D-07 / D-09** — most likely to stay divergent: page geometry and font
   fallbacks are genuinely delivery-channel concerns.
5. **Snap the near-matches** in §3.1. By definition none produces a visible
   change; the docs canvas is the only one with a real (≈1%) delta.
6. **Standing note on the D-00 exemption.** Any *future* row added without a
   literal behind it fails B2 as an orphan — correctly. D-00 survives only
   because it is listed in the checker's `STRUCTURAL_ROWS`. Keep that list
   enumerated: the moment it becomes a pattern, "structural" becomes a way to
   write a divergence nobody has to implement.
