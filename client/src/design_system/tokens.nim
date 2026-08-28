## Design-system token bridge — the WEB lineage (Design-System.md §1/§3).
##
## Two layers, one direction:
##
##   codetracer-design-system/{brand,alias,mapped}/*.json     ← product lineage
##            │  DTCG `{group.token}` alias resolution
##            ▼
##   client/src/design_system/web.tokens.json                 ← web lineage
##            │  this module
##            ▼
##   :root{ --bt-* }  +  the dark block  +  [data-theme]  +  [data-register]
##
## `web.tokens.json` is the ONLY place a web-lineage design value is decided.
## Every leaf in it is either
##
##   * **bkToken**   — `$value` is a `{ref}` into brand/alias/mapped, resolved
##                     here across all three files, or
##   * **bkLiteral** — a concrete value no lineage supplies, which MUST name a
##                     divergence row in `docs/DESIGN-DIVERGENCES-WEB.md` via
##                     `$extensions["bt.divergence"]`.
##
## That binding kind is what makes Design-System.md §4.1 enforceable, and
## `tools/design/check-tokens.mjs` is the check. Nothing in
## `components/styles.nim` or any page may reference a brand primitive or write
## a raw colour or pixel value: Layer 2 sees `var(--bt-*)` and utility classes
## and nothing else (`verify_no_raw_values_in_views`).
##
## VD.2 deliberately stopped emitting the old `--ct-*` primitive ramp. It was a
## parallel vocabulary in which `var(--ct-color-brand-400)` in a page WORKED,
## so the lint against brand primitives in Layer 2 was the only thing standing
## between the product and a second, untracked design system. Now such a
## reference is both linted AND undefined.
##
## ── Variable naming ────────────────────────────────────────────────────────
## The JSON path becomes the variable name by dropping the group prefix and
## joining the rest with `-`:
##
##   base.type.h1.size          → --bt-type-h1-size      (drop 1 segment)
##   theme.light.surface.canvas → --bt-surface-canvas    (drop 2 segments)
##   register.debugger.density.cell-y → --bt-density-cell-y (drop 2 segments)
##
## `tools/design/check-tokens.mjs` derives the same names from the same file,
## so the checker and the emitter cannot drift: there is one source of truth.
##
## ── The design system is located identically in dev and in CI ──────────────
##   1. `DESIGN_SYSTEM_SRC` env var, when set (exported by flake.nix), else
##   2. the `codetracer-design-system` checkout beside the blocktracer repo.

import std/[os, json, strutils, tables, algorithm]

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

proc webTokensPath*(): string =
  ## The web-lineage DTCG file, beside this module.
  currentSourcePath().parentDir / "web.tokens.json"

# ── DTCG token loading + reference resolution ──────────────────────────────

type TokenSpace = object
  roots: seq[JsonNode]  ## brand, alias, mapped — searched in order.

proc loadTokenSpace(dsDir: string): TokenSpace =
  ## Load the three canonical DTCG files. Missing files are a hard, loud error:
  ## the whole point of the gate is that these resolve.
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

proc numToStr(v: JsonNode): string =
  case v.kind
  of JInt: $v.getInt
  of JFloat: formatFloat(v.getFloat, ffDecimal, 2).strip(chars = {'0'}).strip(chars = {'.'})
  else: ""

proc resolve(space: TokenSpace, path: string, seen: var seq[string]): string =
  ## Resolve a token path to a concrete value, following `{ref}` chains.
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
  of JInt, JFloat:
    return numToStr(v)
  else:
    raise newException(ValueError, "unsupported token value kind for " & path)

# ── The web lineage ────────────────────────────────────────────────────────

type
  BindingKind* = enum
    bkToken    ## `$value` was a `{ref}` into brand/alias/mapped
    bkLiteral  ## a web-lineage-specific value; needs a divergence row

  WebToken* = object
    cssVar*: string       ## `--bt-…`
    value*: string        ## the resolved CSS value
    kind*: BindingKind
    counterpart*: string  ## the brand path, for bkToken; "" for bkLiteral
    divergence*: string   ## the divergence row id, for bkLiteral; "" otherwise
    group*: string        ## `base` | `theme.light` | `theme.dark` | `register.*`

const
  ## `$type`s whose numeric resolved value is a px length. A DTCG dimension in
  ## the brand ramp is a bare number (`scale.450 = 12`), so the unit is applied
  ## here rather than being written into every reference.
  DimensionTypes = ["dimension"]

proc isRef(s: string): bool = s.startsWith("{") and s.endsWith("}")

proc leafValue(space: TokenSpace, node: JsonNode, path: string,
               kind: var BindingKind, counterpart: var string): string =
  ## Resolve one web-lineage leaf, and report how it bound.
  let v = node["$value"]
  let ty = if "$type" in node: node["$type"].getStr else: ""
  var raw: string
  case v.kind
  of JString:
    let s = v.getStr
    if s.isRef:
      kind = bkToken
      counterpart = s[1 ..< ^1]
      var seen: seq[string]
      raw = space.resolve(counterpart, seen)
    else:
      kind = bkLiteral
      counterpart = ""
      raw = s
  of JInt, JFloat:
    kind = bkLiteral
    counterpart = ""
    raw = numToStr(v)
  else:
    raise newException(ValueError, "unsupported $value kind at " & path)

  # A resolved dimension that came back as a bare number is px.
  if ty in DimensionTypes and raw.len > 0 and
     raw.allCharsInSet({'0'..'9', '.', '-'}):
    raw = raw & "px"
  # A family name may contain spaces, so it is quoted here rather than in
  # every rule that uses it. Fallback stacks are `$type: string` and are not.
  if ty == "fontFamily":
    raw = "'" & raw & "'"
  raw

proc cssVarName(path: seq[string]): string =
  ## base.type.h1.size → --bt-type-h1-size ; theme.light.surface.canvas →
  ## --bt-surface-canvas ; register.debugger.density.cell-y → --bt-density-cell-y
  let drop = if path[0] == "base": 1 else: 2
  "--bt-" & path[drop .. ^1].join("-")

proc collect(space: TokenSpace, node: JsonNode, path: seq[string],
             group: string, acc: var seq[WebToken]) =
  if node.kind != JObject: return
  if "$value" in node:
    var kind: BindingKind
    var counterpart: string
    let value = leafValue(space, node, path.join("."), kind, counterpart)
    var divergence = ""
    if "$extensions" in node and "bt.divergence" in node["$extensions"]:
      divergence = node["$extensions"]["bt.divergence"].getStr
    if kind == bkLiteral and divergence.len == 0:
      # Fail the BUILD, not just the lint: an untracked literal must never get
      # as far as a rendered page (Design-System.md §4.1).
      raise newException(ValueError,
        "untracked web-lineage literal at " & path.join(".") & " = '" & value &
        "'\nEvery bkLiteral needs $extensions[\"bt.divergence\"] naming a row " &
        "in docs/DESIGN-DIVERGENCES-WEB.md")
    acc.add WebToken(cssVar: cssVarName(path), value: value, kind: kind,
                     counterpart: counterpart, divergence: divergence,
                     group: group)
    return
  for k in node.keys:
    if k.startsWith("$"): continue
    collect(space, node[k], path & @[k], group, acc)

proc loadWebTokens*(): seq[WebToken] =
  ## Every `--bt-*` token, resolved, with its binding kind. This is what both
  ## the CSS emitter and `client/tests/test_static_export.nim` read.
  let space = loadTokenSpace(designSystemDir())
  let web = parseJson(readFile(webTokensPath()))
  for top in ["base", "theme", "register"]:
    if top notin web:
      raise newException(ValueError, "web.tokens.json is missing the '" & top & "' group")
  collect(space, web["base"], @["base"], "base", result)
  for sub in ["light", "dark"]:
    if sub notin web["theme"]:
      raise newException(ValueError, "web.tokens.json: theme." & sub & " is missing")
    collect(space, web["theme"][sub], @["theme", sub], "theme." & sub, result)
  for sub in ["explorer", "debugger"]:
    if sub notin web["register"]:
      raise newException(ValueError, "web.tokens.json: register." & sub & " is missing")
    collect(space, web["register"][sub], @["register", sub], "register." & sub, result)

# ── CSS emission ───────────────────────────────────────────────────────────

proc declarations(toks: seq[WebToken], group: string): string =
  var names: seq[string]
  var byName = initTable[string, string]()
  for t in toks:
    if t.group == group:
      names.add t.cssVar
      byName[t.cssVar] = t.value
  names.sort()
  for n in names:
    result.add n & ":" & byName[n] & ";"

proc buildTokensCss(toks: seq[WebToken]): string =
  ## Design-System.md §7: light and dark for both registers via
  ## `prefers-color-scheme` PLUS an explicit `[data-theme]` override; the
  ## explorer defaults to light, the debugger defaults to dark, and a user's
  ## explicit choice overrides both.
  let base = declarations(toks, "base")
  let light = declarations(toks, "theme.light")
  let dark = declarations(toks, "theme.dark")
  let explorer = declarations(toks, "register.explorer")
  let debugger = declarations(toks, "register.debugger")

  # 1. Light is the explorer's default, and every theme-independent token.
  result.add ":root{" & base & explorer & light & "}\n"
  # 2. Dark when the user's OS asks for it and no explicit choice overrides.
  result.add "@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){" & dark & "}}\n"
  # 3. The explicit override, either direction. Wins over the media query.
  result.add "[data-theme=\"light\"]{" & light & "}\n"
  result.add "[data-theme=\"dark\"]{" & dark & "}\n"
  # 4. The debugger register: dense, dark by default — but an explicit
  #    [data-theme="light"] still wins, per §7.
  result.add "[data-register=\"debugger\"]{" & debugger & dark & "}\n"
  result.add "[data-register=\"debugger\"][data-theme=\"light\"]{" & light & "}\n"

var cachedCss: string  ## Emitted CSS is stable per build; resolve once.

proc emitTokensCss*(): string =
  ## The full `--bt-*` layer: `:root`, the dark block, both `[data-theme]`
  ## overrides and the debugger register. Cached after first call.
  if cachedCss.len == 0:
    cachedCss = buildTokensCss(loadWebTokens())
  cachedCss
