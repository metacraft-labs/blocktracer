## Design-system token bridge.
##
## Reads the canonical Metacraft brand tokens straight from
## `codetracer-design-system` (the W3C-DTCG `brand/`, `alias/`, `mapped/` JSON
## — the single source of truth) and emits them as `--ct-*` CSS custom
## properties. Every component's CSS resolves its colours, fonts, spacing and
## radii from these variables (see components/styles.nim), so nothing is an
## ad-hoc hex/px literal — that is the B-M1 "consume the design system, not
## ad-hoc CSS" gate.
##
## Resolution is genuine DTCG dereferencing: a token whose `$value` is a
## reference like `{colors.indigo.600}` (or a chain alias→brand,
## mapped→alias→brand) is followed across all three files until it lands on a
## concrete hex / number. Numeric primitives (the `scale.N` ramp, in px) become
## `<n>px`.
##
## The design system is located identically whether it is a workspace sibling
## (local dev) or a pinned Nix flake input (hermetic CI build):
##   1. `DESIGN_SYSTEM_SRC` env var, when set (exported by flake.nix), else
##   2. the `codetracer-design-system` checkout beside the blocktracer repo
##      (absolute, derived from this module's own path so it is CWD-independent).
##
## This bridge is lifted verbatim from codetracer-web-site so the blocktracer
## explorer consumes exactly the same DTCG token source of truth; only the
## sibling-fallback path differs, because this client lives one level deeper
## (blocktracer/client/…) than a top-level site repo.

import std/[os, json, strutils]

proc designSystemDir*(): string =
  ## Absolute path to the codetracer-design-system source tree.
  let env = getEnv("DESIGN_SYSTEM_SRC")
  if env.len > 0:
    return env
  # This module: <repo>/client/src/design_system/tokens.nim. Walk up to the
  # blocktracer repo root, then to its parent workspace, where the design system
  # sits as a sibling checkout (…/codetracer-design-system).
  let clientRoot = currentSourcePath().parentDir.parentDir.parentDir  # <repo>/client
  let repoRoot = clientRoot.parentDir                                 # <repo>
  result = repoRoot.parentDir / "codetracer-design-system"

# ── DTCG token loading + reference resolution ──────────────────────────────

type TokenSpace = object
  roots: seq[JsonNode]  ## brand, alias, mapped — searched in order.

proc loadTokenSpace(dsDir: string): TokenSpace =
  ## Load the three canonical DTCG files. Missing files are a hard, loud error:
  ## the whole point of B-M1 is that these resolve.
  for rel in ["brand/brand.json", "alias/alias.json", "mapped/mapped.json"]:
    let path = dsDir / rel
    if not fileExists(path):
      raise newException(IOError,
        "codetracer-design-system token file not found: " & path &
        "\n(set DESIGN_SYSTEM_SRC or place the design system beside this repo)")
    result.roots.add parseJson(readFile(path))

proc getByPath(root: JsonNode, path: string): JsonNode =
  ## Navigate a dotted DTCG path (segments may contain spaces, e.g.
  ## "border radius"); return nil if any segment is absent.
  var node = root
  for seg in path.split('.'):
    if node.kind != JObject or seg notin node:
      return nil
    node = node[seg]
  node

proc lookup(space: TokenSpace, path: string): JsonNode =
  ## First root (brand → alias → mapped) that contains the full path.
  for root in space.roots:
    let n = getByPath(root, path)
    if n != nil:
      return n
  nil

proc resolve(space: TokenSpace, path: string, seen: var seq[string]): string =
  ## Resolve a token path to a concrete CSS value, following `{ref}` chains.
  if path in seen:
    raise newException(ValueError, "cyclic token reference: " & path)
  seen.add path
  let node = space.lookup(path)
  if node == nil:
    raise newException(ValueError, "unknown design-system token: " & path)
  if node.kind != JObject or "$value" notin node:
    raise newException(ValueError, "not a leaf token: " & path)
  let v = node["$value"]
  case v.kind
  of JString:
    let s = v.getStr
    if s.startsWith("{") and s.endsWith("}"):
      return space.resolve(s[1 ..< ^1], seen)
    return s
  of JInt:
    return $v.getInt
  of JFloat:
    return formatFloat(v.getFloat, ffDecimal, 2).strip(chars = {'0'}).strip(chars = {'.'})
  else:
    raise newException(ValueError, "unsupported token value kind for " & path)

proc color(space: TokenSpace, path: string): string =
  var seen: seq[string]
  space.resolve(path, seen)

proc px(space: TokenSpace, path: string): string =
  var seen: seq[string]
  space.resolve(path, seen) & "px"

proc fontStack(space: TokenSpace, path: string, fallbacks: string): string =
  ## A DTCG font-family token → a real CSS font stack. The primary family name
  ## comes verbatim from the token (so the linkage to the design system is
  ## literal); fallbacks are appended for coverage.
  var seen: seq[string]
  let family = space.resolve(path, seen)
  "'" & family & "', " & fallbacks

# ── CSS emission ───────────────────────────────────────────────────────────

proc buildTokensCss(space: TokenSpace): string =
  ## Emit `:root{ --ct-*: … }` from resolved design-system tokens.
  var vars: seq[(string, string)]

  # Brand + neutral colour ramps (semantic aliases → brand primitives).
  for step in ["100", "200", "300", "400", "500", "600", "700", "800", "900"]:
    vars.add ("--ct-color-brand-" & step, space.color("colors.brand." & step))
  for step in ["50", "100", "150", "200", "250", "300", "350", "400", "450",
               "500", "550", "600", "650", "700", "750", "800", "850", "900",
               "950", "1000"]:
    vars.add ("--ct-color-neutral-" & step, space.color("colors.neutral." & step))
  for step in ["300", "400", "500", "600"]:
    vars.add ("--ct-color-secondary-" & step, space.color("colors.secondary." & step))

  # Semantic status colours.
  vars.add ("--ct-color-success", space.color("colors.success.500"))
  vars.add ("--ct-color-error", space.color("colors.error.500"))
  vars.add ("--ct-color-warning", space.color("colors.warning.500"))
  vars.add ("--ct-color-information", space.color("colors.information.500"))

  # Mapped UI tokens (borders / dividers) — proof the mapped layer resolves.
  vars.add ("--ct-border-primary", space.color("colors.ui.border.primary"))
  vars.add ("--ct-border-action", space.color("colors.ui.border.action"))
  vars.add ("--ct-border-focus", space.color("colors.ui.border.focus"))
  vars.add ("--ct-divider-subtle", space.color("colors.ui.divider.subtle"))

  # Convenience surface/text/action aliases for component authoring.
  vars.add ("--ct-bg", space.color("colors.neutral.1000"))
  vars.add ("--ct-bg-raised", space.color("colors.neutral.900"))
  vars.add ("--ct-fg", space.color("colors.neutral.50"))
  vars.add ("--ct-fg-muted", space.color("colors.neutral.300"))
  vars.add ("--ct-action", space.color("colors.brand.600"))
  vars.add ("--ct-action-hover", space.color("colors.brand.500"))
  vars.add ("--ct-on-action", space.color("colors.base.white"))

  # Typography.
  vars.add ("--ct-font-sans",
    space.fontStack("type.fontFamily.ui-primary",
      "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif"))
  vars.add ("--ct-font-mono",
    space.fontStack("type.fontFamily.code-primary",
      "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace"))

  # Font-size ramp (px).
  for name in ["2xs", "xs", "sm", "md", "lg", "xl", "2xl", "3xl", "4xl"]:
    vars.add ("--ct-text-" & name, space.px("type.fontSize." & name))

  # Spacing scale (px), from the alias padding ramp.
  for name in ["3xs", "2xs", "xs", "sm", "md", "lg", "xl", "2xl", "3xl"]:
    vars.add ("--ct-space-" & name, space.px("padding." & name))

  # Border-radius scale (px).
  for name in ["2xs", "xs", "sm", "md", "lg", "xl", "2xl"]:
    vars.add ("--ct-radius-" & name, space.px("border.border radius." & name))

  result = ":root{\n"
  for (k, v) in vars:
    result.add "  " & k & ": " & v & ";\n"
  result.add "}\n"

var cachedCss: string  ## Emitted CSS is stable per build; resolve once.

proc emitTokensCss*(): string =
  ## `:root{…}` with every `--ct-*` variable resolved from
  ## codetracer-design-system. Cached after first call.
  if cachedCss.len == 0:
    let space = loadTokenSpace(designSystemDir())
    cachedCss = buildTokensCss(space)
  cachedCss
