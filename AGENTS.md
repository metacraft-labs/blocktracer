# blocktracer — AGENTS.md

[blocktracer.org](https://blocktracer.org) — a block/transaction explorer. The
browsable web front-end is an **isonim** static site living in **`client/`**;
the repo root holds the Nim CLI tools that generate, validate, and publish the
trace/chain data the site renders.

**Two Justfiles — mind which one:**
- **Repo root `Justfile`** — data-pipeline tasks (`just test`, `demo-gen`,
  `validate`, `demo`, `publish`, `build`) over root `src/` (`blocktracer_*.nim`).
- **`client/Justfile`** — the isonim site. Run its targets as
  **`cd client && just …`**. Everything in §3–§5 below refers to this one.

## 1. Purpose & how it ships

**To change site content and ship it, follow
[`metacraft-dev-guidelines/policies/managing-web-site-content.md`](../metacraft-dev-guidelines/policies/managing-web-site-content.md).**
Edit `client/src/`, test locally (§4), open a PR to the target branch, and merge.
**Merging auto-deploys — there is no manual deploy step.**

Branch → Cloudflare Pages project (one project per env; see
`.github/workflows/deploy.yml`). This publishes the **demo / static explorer**;
CI builds hermetically via `nix build .#default` and deploys with
flake-pinned `wrangler pages deploy`:

| Branch | Pages project | Preview alias |
|--------|---------------|---------------|
| `live` | `blocktracer` | — (production) |
| `staging` | `blocktracer-staging` | — |
| `dev` | `blocktracer-dev` | — |
| any PR | `blocktracer-dev` | `<head-ref>.blocktracer-dev.pages.dev` |

The production **blocktracer.org** apex is served by a separate **Cloudflare R2
delta-publisher** path (bucket bound to the `blocktracer.org` zone), documented
in [`DEPLOY.md`](./DEPLOY.md) — not by the Pages projects above.

## 1a. `@blocktracer/client` — the Client SDK (M12a)

The chain-aware read layer lives in **`src/blocktracer_client.nim`** (the
facade) plus `src/blocktracer_client/**` (private). It reads the published
`/d/**` tree, pins a generation, resolves a transaction to a trace, parses and
emits debug deep links, and resolves source bundles per code hash. Spec:
[`../codetracer-specs/BlockTracer/Client-SDK.md`](../codetracer-specs/BlockTracer/Client-SDK.md).

**Two layers, one direction.** The Client SDK depends on the CodeTracer **Embed
SDK** (`codetracer_embed`, in the `codetracer` repo) and never the reverse. The
dependency lives in exactly one module, `src/blocktracer_client_embed.nim`,
which converts a `ResolvedTrace` into the Embed SDK's `TraceSource`. Everything
else compiles with no debugger on the Nim path at all — that is the layering,
not a comment about it.

| Rule | Enforced by |
|------|-------------|
| A consumer imports only `blocktracer_client` (or `blocktracer_client_embed`) | `ci/test/client-sdk-boundary.sh` |
| The SDK reaches no renderer, no producer, no socket, no identity | same |
| The Embed SDK contains no chain concept and never imports this package | same, `--embed-root` / `$CODETRACER_SRC` |
| Every rule above actually bites | `ci/test/client-sdk-boundary-test.sh` (synthetic trees with deliberate violations) |

`client/` is a **declared consumer** (`client/.sdk-consumer`): `client/src/reader.nim`
is now a presentation projection over the SDK, not a second reader.

| Command | What it does |
|---------|--------------|
| `just sdk-test` | `tests/tclientsdk.nim` — the consumer-side conformance suite (no Embed SDK needed) |
| `just sdk-boundary` | the bidirectional import lint plus its own self-test |
| `just sdk-test-embed` | `tests/tembedhandoff.nim` against the real Embed SDK; needs `$CODETRACER_SRC` or a `../codetracer` checkout — pinned commit in `ci/embed-sdk-pin.env` |

## 2. isonim architecture

**isonim** is a cross-platform reactive UI framework for Nim (signals / effects /
memos, no virtual DOM; SolidJS-inspired). This site uses only the **server-side
HTML string** path (`renderToString`) to statically export pages. Framework
overview: [`../isonim/README.md`](../isonim/README.md).

Layout under **`client/src/`**:

| Path | Role |
|------|------|
| `ssr.nim` | **Route table** (`staticRoutes`) + `renderRoute` dispatcher; `SiteDomain = "https://blocktracer.org"` for canonical URLs |
| `static_export.nim` | Export entry (`just export` compiles & runs it → `dist/`) |
| `reader.nim`, `viewutil.nim` | Chain-data loading + view helpers |
| `pages/*.nim` | `home`, `chain`, `blocklist`, `blockview`, `tx` |
| `components/*.nim` | `layout` (site shell), `styles`, `nav`, `footer`, `tables` |
| `design_system/tokens.nim` | Design-system tokens |

**Route table** (`client/src/ssr.nim`) — routes are **data-derived** (one per
chain / block / tx), not a fixed page list:

```
/                        → home
/<chain>                 → chain overview      (e.g. /aztec)
/<chain>/blocks          → block list
/<chain>/block/<hash>    → block detail
/<chain>/tx/<hash>       → transaction detail
```

`staticRoutes` enumerates the concrete URLs to pre-render from the chain data;
`renderRoute` dispatches by pattern (unknown → 404). **To add a page kind, add a
pattern to both `staticRoutes` enumeration and `renderRoute`.**

Reference guides (the isonim-docs SSG is a sibling consumer of isonim; these
cover routing, live components, theming, and the API/library reference model):
[getting-started](../isonim-docs/site/content/getting-started.md),
[components](../isonim-docs/site/content/components.md),
[routing](../isonim-docs/site/content/routing.md),
[api-reference](../isonim-docs/site/content/api-reference.md),
[library-reference](../isonim-docs/site/content/library-reference.md),
[theming](../isonim-docs/site/content/theming.md).

## 3. Idiomatic DSL

Pages are `proc(data): string` whose body is a single `ui:` block. Because
routes are data-driven, pages take typed chain data as parameters and use plain
Nim `for`/`if` **inside** the `ui:` block. Reserved-word attributes are
backtick-escaped (`` `method` ``, `` `type` ``).

```nim
import isonim/dsl/ui, isonim/ssr/escape

proc homePage*(infos: seq[ChainInfo]): string =
  ui:
    section(class = "sec hero"):
      tdiv(class = "inner"):
        h1(class = "display"):
          text "Step "
          span(class = "accent"):
            text "backwards"
          text " through any transaction."
        form(class = "search", action = "/search", `method` = "get"):
          input(name = "q", placeholder = "Paste a block, tx hash, or address")
          button(class = "btn primary", `type` = "submit"):
            text "Search"
```

Do:
- Use `tdiv` for `<div>`; attributes as keyword args; backtick-escape Nim
  reserved words used as attribute names (`` `method` ``, `` `type` ``).
- Emit text with `text "..."` (auto-escaped); splice rendered children/CSS with
  `raw`. Drive lists/conditionals with ordinary Nim `for`/`if` in the block.
- Assemble the page shell CSS in `layout.nim` from
  `emitTokensCss() & fontFaceCss & globalCss`.

Don't:
- Don't hand-concatenate HTML or hardcode design values — use `tables.nim`
  helpers and `design_system/tokens.nim`.
- **Don't write a raw colour, a raw pixel value, a brand primitive, an inline
  `style=` attribute, or a hand-built HTML fragment in a page or component.**
  Layer 2 sees semantic `var(--bt-*)` tokens and utility classes and nothing
  else. This is checked: `node tools/design/check-tokens.mjs` (a step of the
  `visual-design` CI job) fails on any of them — A1 colours, A2 lengths, A3
  primitives, **A5 inline styles**, **A7 hand-built markup** — and
  `check-tokens-selftest.mjs` proves it by planting each violation in the real
  source and restoring it byte-identically.
- "Raw colour" includes the **CSS system colours** (`ButtonFace`, `Canvas`,
  `CanvasText`, `LinkText`, `Field`, `Highlight`, `GrayText`, `AccentColor`,
  and the rest of the CSS Color 4 set). `ButtonFace` is not a footnote: it is
  the value that made the primary action measure 1.04:1, because `.btn` set no
  `background` and the user agent supplied one.
- Every string literal in a Layer 2 file is scanned, not only the ones that
  look like CSS. A colour inside a `raw "<span style=…>"` fragment and a colour
  in a bare attribute value (`meta(name = "theme-color", content = "#4f46e5")`)
  both fail. So do the ways of writing the same value that a text search misses:
  a CSS identifier escape (`\42 uttonFace`), a Nim numeric escape
  (`"\x42uttonFace"`), a value split across a `&` concatenation, `@IMPORT` in
  another case, and the whole of CSS Color 4 and CSS Values 4 — `hwb()`,
  `color()`, `100dvh`, `20cqw`.
- **A Layer 2 view lives in `client/src/components/` or `client/src/pages/`.**
  A `.nim` anywhere else under `client/src` that imports the isonim DSL or
  carries a stylesheet fails A0, because the two-directory scan cannot see it
  and every other rule would then report a clean pass over a subset.
- Three things the checker knowingly does NOT catch, listed so nobody assumes
  otherwise: a value built at run time from non-literal parts; a value routed
  through a `const` in a module outside those two directories; and — in the
  other direction — a single-word capitalised label such as `text "Menu"` or
  `text "Orange"`, which fails A1 as a colour. Long prose is safe; a one-word
  label that happens to be a colour name is not.
- **Cite a review finding as `ledger@<revision>:<id>`** — e.g.
  `ledger@2026-08-28.3:tx-detail/wide/light/L1/8`. A round that replaces its
  predecessor reuses the ids, so an unversioned `L1/1` silently comes to mean a
  different finding; check B4 fails on a citation that no longer resolves.

### The design tokens (VD.2)

One source of truth: **`client/src/design_system/web.tokens.json`**, the *web
lineage* of the CodeTracer design system. `tokens.nim` emits it as `--bt-*`
custom properties — `:root` (light + theme-independent), a
`prefers-color-scheme: dark` block, both `[data-theme]` overrides, and
`[data-register="debugger"]`; `check-tokens.mjs` reads the same file, so the
emitter and the linter cannot drift.

Every leaf is either **`bkToken`** (a `{ref}` into the pinned
`codetracer-design-system` brand/alias/mapped JSON) or **`bkLiteral`** (a value
no lineage supplies), and a `bkLiteral` MUST name a row in
`docs/DESIGN-DIVERGENCES-WEB.md` — `tokens.nim` raises at BUILD time if it does
not, so an untracked literal never reaches a page.

The primitive `--ct-*` ramp is deliberately no longer emitted. A brand
primitive in a view is therefore undefined as well as forbidden.

Adding a design value:

1. Add the token to `web.tokens.json`, as a `{ref}` if the brand has one.
2. If it is a literal, add `$extensions: {"bt.divergence": "D-nn"}` and the
   matching row in `docs/DESIGN-DIVERGENCES-WEB.md`.
3. `node tools/design/check-tokens.mjs --write-bindings` to refresh §4's table.
4. `just design-verify`.
- Don't push untrusted strings through `raw`.

## 4. Local testing & iteration

Exact `client/Justfile` targets (run from `client/`; verified):

| Command | What it does |
|---------|--------------|
| `cd client && just test` | Runs `tests/test_static_export.nim` |
| `cd client && just export` | Compiles + runs `src/static_export.nim` → writes `dist/` |
| `cd client && just preview` | Runs `export`, then serves `dist/` at **http://localhost:8080** |
| `cd client && just clean` | Removes `dist/ nimcache` + built test/export binaries |

`just preview` is a plain static server (rebuild + refresh — **no hot reload**).
isonim's framework dev server offers websocket live-reload (see
[dev-server.md](../isonim-docs/site/content/dev-server.md)) but this repo's
Justfile does not wire it up.

## 5. The isonim editor

**Not present.** There is no `client/src/editor/`, no `EditorWorkspace`, and no
`editor` target in either Justfile. (The sibling isonim sites
`metacraft-web-site` and `reprobuild-web-site` ship a read-only editor workspace
and are the model to follow if one is added here.)
