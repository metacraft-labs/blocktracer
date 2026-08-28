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
        h1(class = "h1"):
          text "Step "
          span(style = "color:var(--ct-color-brand-400)"):
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
