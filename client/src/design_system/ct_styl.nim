## A Stylus-subset transpiler, so BlockTracer can SERVE CodeTracer's component
## stylesheets instead of paraphrasing them.
##
## ## Why this module exists at all
##
## CodeTracer's component style layer is Stylus: `src/frontend/styles/
## components/*.styl`, compiled by `node stylus` in its Nix build. BlockTracer
## tracks no `.css`/`.scss`/`.styl` file of any kind — every byte of its CSS is
## a string literal in Nim, emitted by `components/styles.nim` and
## `components/debugger_css.nim` and inlined into each exported page.
##
## Those two facts are why the debugger looked like a different product. The
## rules that draw CodeTracer's tab bars, splitters, panel edges and panel
## internals are written against `.lm_*`, `.data-table`, `.ct-button-*` and
## `.ct-notification-*`; BlockTracer's markup spelled the same ideas `.pane`,
## `.panehead`, `.stacktab`, `.btn`. No amount of token adoption can bridge
## that: a token carries a colour, not a rule.
##
## ## The two honest mechanisms, and why this one
##
##   (b) ADD STYLUS TO THE BUILD and consume the real `.styl` files.
##       Rejected on three measured grounds. First, it puts `node` + the
##       `stylus` package on the critical path of a build whose own check
##       scripts state they "must run on a bare CI runner with nothing
##       installed beyond a shell and Nim" (`ci/test/layout-model-vendor.sh`).
##       Second, `codetracer.styl` resolves its identifiers through
##       `styles/generated/{brand,alias,mapped}.styl`, which are generated from
##       the SAME `codetracer-design-system` DTCG files that BlockTracer's
##       `web.tokens.json` already resolves against — so consuming them raw
##       would stand up a second, untracked token vocabulary beside `--bt-*`
##       and put every rule outside `tools/design/check-tokens.mjs`. Third,
##       CodeTracer's `.styl` has exactly one theme baked in; BlockTracer's
##       debugger register ships light AND dark.
##
##   (a) PORT THE RULES. Taken — but mechanically, not by retyping. The `.styl`
##       sources are vendored BYTE-VERBATIM from the pinned CodeTracer commit
##       (`client/src/debugger/vendor/frontend/styles/components/`, manifest
##       `ct_styles.vendor.json`, gate `ci/test/ct-styles-vendor.sh`) and this
##       module compiles them. Nobody re-types a declaration, so the two
##       products cannot drift by a hand slipping; they can only drift by
##       upstream moving, which is precisely what the vendor gate reports.
##
## The single source of truth is therefore the vendored bytes, and the only
## BlockTracer-authored inputs are (1) the identifier bridge, which maps a
## CodeTracer role name onto the `--bt-*` role that already carries the same
## value, and (2) the small, listed set of rules dropped because the markup
## they address cannot exist here. Both are declared in
## `components/ct_components_css.nim` and both are reported.
##
## ## The subset
##
## Everything the vendored files use, and nothing else. A construct outside
## the subset RAISES rather than being silently skipped — a transpiler that
## quietly drops what it does not understand is how a port comes to differ from
## its origin without anyone noticing.
##
##   * indentation nesting, `&` parent references, descendant defaulting
##   * selector GROUPS, both comma-terminated and Stylus's bare
##     one-selector-per-line form (`.ct-input-small` / `.ct-input-panel`)
##   * `NAME = value` assignments, resolved recursively, collected across all
##     inputs in a pre-pass (so `button.styl`'s `PANEL_INSET` reaches
##     `golden_layout.styl`, exactly as `codetracer.styl`'s import order does)
##   * `//` line comments and `/* … */` block comments, both stripped
##   * `@import` lines, skipped (the generated token layer is replaced by the
##     bridge)
##   * a value whose parentheses span several lines (`linear-gradient(` with one
##     stop per line), joined into one declaration
##   * `@keyframes NAME` — emitted as ONE rule, never scoped: a keyframe stop
##     is not a selector, and an animation name is global to the document
##   * `@media QUERY` — emitted as a block whose inner rules are scoped like
##     any other rule
##   * `by-mode(dark, light)`, upstream's build-time theme switch, resolved to
##     one arm (`resolveByMode`)
##
## NOT in the subset, and each one raises: `@supports` and every other
## at-rule, `if`/`else`/`for`/`unless` beyond the listed build conditions,
## `@extend`, interpolation `{…}`. Where a vendored file uses one, the
## enclosing rule is named in `dropRules` with a reason.
##
## ## What happens to an identifier the bridge does not carry
##
## The declaration is DROPPED and recorded in `unresolved`. That is not a
## shortcut, it is fidelity: Stylus emits an unknown bare identifier verbatim,
## and a browser then discards the declaration as a parse error. Dropping it
## here produces the same computed style CodeTracer itself produces, and the
## record is what lets a test assert the list is the SHORT one we expect rather
## than half the stylesheet.
##
## ## What happens to a `url()`
##
## IT IS REWRITTEN, AND A URL THIS MODULE CANNOT PLACE IS A BUILD ERROR.
##
## For a long time `url()` was passed through unchanged, and that was a
## MEASURED production defect rather than a theoretical one. Two vendored
## sheets name their icons relative to the sheet's own place in CodeTracer's
## source tree — `button.styl` writes
## `url("../../../public/resources/origin-icons/sigma.svg")` — and the emitted
## CSS is served from `/_a/<hash>.css`, so a browser resolved that to
## `/public/resources/origin-icons/sigma.svg`: a path this site has never
## published. 9 of the 13 `url()`s in the built stylesheet were 404 for every
## visitor, and all 9 were inside the `[data-register="debugger"]` scope — the
## debugger panels, which are the whole visual-parity goal.
##
## THE FIX IS HERE AND NOT IN THE VENDORED BYTES, for the reason this module
## exists at all. Hand-editing `button.styl` would make it diverge from upstream
## (`ci/test/ct-styles-vendor.sh` compares sha256 against the pinned commit and
## would go red by construction), would be reverted by the next re-vendor, and
## would be exactly the "a hand slipped" drift the header above refuses. A url
## is a BUILD DECISION about where this product publishes a file, which is what
## `StylPort` is for.
##
## So `StylPort.assetUrls` maps a vendored relative url onto the published path
## of BlockTracer's own copy, and the mapping is TOTAL AND LOUD:
##
##   * `/…`, `data:`, `http(s):`, `//…`, `#…` — the browser does not resolve
##     these against the stylesheet's directory, so neither does this module;
##     they pass through untouched.
##   * a relative url of the shape `…/public/resources/<group>/<file>` resolves
##     through `assetUrls`.
##   * ANYTHING ELSE RAISES. A relative url of an unrecognised shape, and a
##     recognised one with no vendored file behind it, both stop the build.
##     That is the lesson of the defect: the broken url survived for as long as
##     it did because nothing in the pipeline ever refused it. A silent
##     pass-through is how a 404 gets published, so there is no longer one.

import std/[strutils, tables, sequtils]

type
  StylSource* = object
    ## One vendored `.styl` file: its bytes and the upstream path they came
    ## from. The path is what every provenance comment and diagnostic names.
    origin*: string
    text*: string
    definitionsOnly*: bool
      ## Contributes its mixins and `NAME = value` constants and emits NO rule.
      ## For a sheet whose definitions a vendored sheet calls and whose rules
      ## address markup this site does not have: `state.styl` calls
      ## `line-number-type()`, which `text_editor.styl` defines beside the
      ## Monaco editor's rules. Upstream's import order puts the definition in
      ## scope the same way, and its rules are not this port's to emit —
      ## except the top-level rules `emitOnly` names.
    emitOnly*: seq[string]
      ## For a `definitionsOnly` source: the top-level selector lines whose
      ## rules ARE emitted, in source order. `text_editor.styl` also draws the
      ## right-click menu the shared panes open (`#context-menu-container` and
      ## its items), which the live build uses and the editor does not own.

  StylPort* = object
    ## Everything BlockTracer decides, in one place so it can be reported.
    bridge*: OrderedTable[string, string]
      ## CodeTracer stylus identifier → the CSS text that replaces it.
    scope*: string
      ## Prefixed to every emitted selector. `debugRouteCss` is inlined on
      ## EVERY exported page (`components/layout.siteCss`), so an unscoped
      ## `button` or `tr` rule from this port would restyle the explorer, which
      ## a different branch owns.
    literalAliases*: OrderedTable[string, string]
      ## Applied to a declaration's value AFTER identifier substitution, as a
      ## plain text replacement. Exists for the one class of value an
      ## identifier bridge cannot reach: a QUOTED font-family name, which the
      ## two products spell differently for the same face.
    dropRules*: OrderedTable[string, string]
      ## Upstream selector line → why BlockTracer does not emit it. A key may
      ## name its sheet as `<file>.styl: <line>`, and then drops that line in
      ## that sheet only: the same at-rule text (`@media (prefers-reduced-motion:
      ## reduce)`) is in three sheets and is droppable in two of them.
    assetUrls*: OrderedTable[string, string]
      ## `<group>/<file>` (the tail of a vendored `…/public/resources/…` url) →
      ## the URL BlockTracer publishes its own copy of that file at.
      ##
      ## This is the only reason a vendored `url()` can be emitted at all: see
      ## the header's "What happens to a `url()`". An empty table means NO
      ## relative url is placeable, so a source containing one fails the build
      ## rather than emitting it — which is the behaviour a bare `StylPort` in a
      ## test should have.

  StylReport* = object
    ## What the transpile did, for the gate and the PR body to read.
    rules*: int
    declarations*: int
    unresolved*: seq[string]   ## "origin:line  property: value"
    dropped*: seq[string]      ## "origin:line  selector — reason"

  StylError* = object of CatchableError

  Node = ref object
    indent: int
    line: int
    text: string
    kids: seq[Node]

# ── lexing ─────────────────────────────────────────────────────────────────

proc stripComments(text: string): seq[tuple[line: int, s: string]] =
  ## Drop `/* … */` (possibly multi-line) and `//` to end of line.
  ##
  ## `//` is only a comment at the start of a line or after whitespace, which
  ## is what keeps a `url(http://…)` intact. No vendored file names an
  ## OFF-ORIGIN url today, so that guard is still speculative — but note that
  ## this sentence used to be read as "no vendored file has a url", which was
  ## never true: nine RELATIVE `url()`s are vendored (eight in `button.styl`,
  ## one in `shared_widgets.styl`), every one of them was published broken, and
  ## `rewriteUrls` below is what now places them. The `//`-inside-a-url guard
  ## remains for the off-origin case it was written for.
  var inBlock = false
  var lineNo = 0
  for raw in text.splitLines:
    inc lineNo
    var kept = newStringOfCap(raw.len)
    var i = 0
    var quote = '\0'
    while i < raw.len:
      if inBlock:
        if i + 1 < raw.len and raw[i] == '*' and raw[i + 1] == '/':
          inBlock = false
          i += 2
        else:
          inc i
        continue
      let c = raw[i]
      if quote != '\0':
        kept.add c
        if c == quote: quote = '\0'
        inc i
        continue
      if c == '\'' or c == '"':
        quote = c
        kept.add c
        inc i
        continue
      if i + 1 < raw.len and c == '/' and raw[i + 1] == '*':
        inBlock = true
        i += 2
        continue
      if i + 1 < raw.len and c == '/' and raw[i + 1] == '/' and
         (kept.len == 0 or kept[^1] in {' ', '\t'}):
        break
      kept.add c
      inc i
    result.add (lineNo, kept)

proc indentOf(s: string): int =
  for c in s:
    if c == ' ': inc result
    elif c == '\t': result += 2
    else: break

# ── the indentation tree ───────────────────────────────────────────────────

proc buildTree(src: StylSource): seq[Node] =
  ## Lines → a tree by indentation. Assignments and `@import` stay in the tree
  ## as ordinary nodes; the emitter decides what each one is.
  ##
  ## A value whose parentheses do not close on its own line continues on the
  ## next ones (`linear-gradient(` with one stop per line, as `calltrace.styl`
  ## writes its loading hairline): the lines are joined into ONE node at the
  ## first line's indentation, so a continuation is never read as a child
  ## selector. Stylus allows the same split
  ## (https://stylus-lang.com/docs/syntax.html, "Selectors" / "Properties").
  var roots: seq[Node]
  var stack: seq[Node]
  var pending = ""
  var pendingLine, pendingIndent, depth = 0
  for (lineNo, raw) in stripComments(src.text):
    let piece = raw.strip
    if piece.len == 0: continue
    if pending.len == 0:
      pendingLine = lineNo
      pendingIndent = indentOf(raw)
    elif not pending.endsWith("(") and not piece.startsWith(")"):
      pending.add ' '
    pending.add piece
    for c in piece:
      if c == '(': inc depth
      elif c == ')': dec depth
    if depth > 0: continue
    if depth < 0:
      raise newException(StylError, src.origin & ":" & $lineNo &
        ": a ')' with no '(' before it")
    let body = pending
    let ind = pendingIndent
    pending = ""
    let n = Node(indent: ind, line: pendingLine, text: body)
    while stack.len > 0 and stack[^1].indent >= ind:
      discard stack.pop
    if stack.len == 0: roots.add n
    else: stack[^1].kids.add n
    stack.add n
  if depth != 0:
    raise newException(StylError, src.origin & ":" & $pendingLine &
      ": a '(' that never closes")
  roots

# ── values ─────────────────────────────────────────────────────────────────

const IdentStart = {'a'..'z', 'A'..'Z', '_'}
const IdentBody = {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}

proc looksLikeToken(id: string): bool =
  ## An identifier that was MEANT to resolve: a design-system role name, an
  ## image handle, or a Stylus SCREAMING_CASE constant. Anything else is a CSS
  ## keyword (`none`, `inherit`, `nowrap`, `col-resize`) and is left alone.
  if id.startsWith("colors-") or id.startsWith("ct-images-"): return true
  if id.len > 1 and id.allCharsInSet({'A'..'Z', '0'..'9', '_'}): return true
  false

proc substitute(value: string; env: Table[string, string];
                bridge: OrderedTable[string, string];
                depth = 0): string =
  ## Replace every identifier the environment or the bridge knows. Quoted
  ## strings are untouched; an identifier immediately followed by `(` is a CSS
  ## function name, not a value.
  if depth > 16:
    raise newException(StylError, "cyclic stylus variable in value: " & value)
  var i = 0
  var quote = '\0'
  while i < value.len:
    let c = value[i]
    if quote != '\0':
      result.add c
      if c == quote: quote = '\0'
      inc i
      continue
    if c == '\'' or c == '"':
      quote = c
      result.add c
      inc i
      continue
    if c in IdentStart:
      var j = i
      while j < value.len and value[j] in IdentBody: inc j
      let id = value[i ..< j]
      if j < value.len and value[j] == '(':
        result.add id
      elif id in env:
        result.add substitute(env[id], env, bridge, depth + 1)
      elif id in bridge:
        result.add bridge[id]
      else:
        result.add id
      i = j
      continue
    result.add c
    inc i

proc resolveByMode(value: string; env: Table[string, string];
                   bridge: OrderedTable[string, string]): string =
  ## `by-mode(dark, light)` — upstream's BUILD-TIME theme switch
  ## (`src/frontend/styles/defaults.styl`: the light arm when `COLOR_MODE` is
  ## "Light", the dark arm otherwise) — resolved to ONE arm, after the arms are
  ## substituted.
  ##
  ## This register switches theme at RUNTIME, through the `--bt-*` roles, so the
  ## arm it keeps is the one that names a role, for the reason the bridge binds
  ## by role at all: a role is what keeps the light debugger right. The dark arm
  ## wins when it is a role (the register's default theme is dark, which is the
  ## arm upstream's own default build takes); a dark arm that is a raw literal —
  ## `rgba(255, 255, 255, 0.22)` over the checkmarks — would draw white on the
  ## light theme, so the light arm's role is taken instead. With no role in
  ## either, the dark arm, as upstream's build.
  var i = 0
  while i < value.len:
    let hit = value.find("by-mode(", i)
    if hit < 0 or (hit > 0 and value[hit - 1] in IdentBody):
      if hit < 0:
        result.add value[i .. ^1]
        break
      result.add value[i .. hit]
      i = hit + 1
      continue
    result.add value[i ..< hit]
    var depth = 0
    var j = hit + "by-mode(".len
    var args = @[""]
    while j < value.len:
      let c = value[j]
      if c == '(': inc depth
      elif c == ')':
        if depth == 0: break
        dec depth
      if c == ',' and depth == 0: args.add ""
      else: args[^1].add c
      inc j
    if j >= value.len or args.len != 2:
      raise newException(StylError, "by-mode needs two arms: " & value)
    let dark = substitute(args[0].strip, env, bridge)
    let light = substitute(args[1].strip, env, bridge)
    result.add(if "var(--bt-" in dark: dark
               elif "var(--bt-" in light: light
               else: dark)
    i = j + 1

proc isNumericLiteral(s: string): bool =
  ## A bare CSS length/number: optional sign, digits with at most one dot, and
  ## an optional alphabetic unit or `%`. Deliberately narrow — anything richer
  ## is left alone for `foldNegation` to refuse rather than mangle.
  if s.len == 0: return false
  var i = 0
  if s[i] in {'+', '-'}: inc i
  var digits = 0
  var dots = 0
  while i < s.len and (s[i] in {'0'..'9'} or s[i] == '.'):
    if s[i] == '.':
      inc dots
      if dots > 1: return false
    else: inc digits
    inc i
  if digits == 0: return false
  if i < s.len and s[i] == '%': inc i
  else:
    while i < s.len and s[i] in {'a'..'z', 'A'..'Z'}: inc i
  i == s.len

proc foldNegation*(value: string): string =
  ## Stylus's unary minus on a parenthesised value: `-(0.25rem)` -> `-0.25rem`.
  ##
  ## THIS SHIPPED WRONG. `golden_layout.styl:371` writes
  ## `margin-top: -(LAYOUT_TAB_TOP)`, which real Stylus folds to `-0.25rem`.
  ## This transpiler substitutes identifiers TEXTUALLY and had no arithmetic,
  ## so it emitted the literal `margin-top:-(0.25rem)` — not a valid CSS value,
  ## so every browser dropped the declaration and every stack after a splitter
  ## kept the 0.25rem the rule exists to remove. The string was in the
  ## stylesheet blocktracer.org served.
  ##
  ## THE FIX IS HERE AND NOT IN THE VENDORED BYTES, which are verbatim copies
  ## hashed against the pinned commit by `ci/test/ct-styles-vendor.sh`: that
  ## line is upstream's own source and is correct Stylus. The same reasoning
  ## the `url()` port already records.
  ##
  ## CONSERVATIVE ON PURPOSE. Only a `-(` that opens a value position — start
  ## of the value, or after whitespace, `,` or `(` — and only when the contents
  ## are one bare numeric literal. `calc(100% - (2px))` has a space before its
  ## paren and does not match; `-(calc(…))` is not a literal and is left for
  ## the emitted-value gate to report rather than silently rewritten.
  var i = 0
  var quote = '\0'
  while i < value.len:
    let c = value[i]
    if quote != '\0':
      result.add c
      if c == quote: quote = '\0'
      inc i
      continue
    if c == '\'' or c == '"':
      quote = c
      result.add c
      inc i
      continue
    let opensValue = i == 0 or value[i - 1] in {' ', '\t', ',', '('}
    if c == '-' and i + 1 < value.len and value[i + 1] == '(' and opensValue:
      let close = value.find(')', i + 2)
      if close > 0:
        let inner = value[i + 2 ..< close].strip
        if isNumericLiteral(inner):
          if inner.startsWith('-'): result.add inner[1 .. ^1]
          elif inner.startsWith('+'): result.add '-' & inner[1 .. ^1]
          else: result.add '-' & inner
          i = close + 1
          continue
    result.add c
    inc i

proc fmtNum(x: float): string =
  ## Shortest faithful spelling: `1.875`, `2.5`, `5` — never `5.0`, which is
  ## valid CSS but is not what Stylus prints, and a diff against upstream's
  ## output should be empty for the same input.
  result = formatFloat(x, ffDecimal, 6).strip(leading = false, chars = {'0'})
  if result.endsWith('.'): result.setLen(result.len - 1)
  if result.len == 0: result = "0"

proc splitNumUnit(s: string): tuple[num: float, unit: string, ok: bool] =
  if not s.isNumericLiteral: return (0.0, "", false)
  var i = 0
  if s[i] in {'+', '-'}: inc i
  while i < s.len and (s[i] in {'0'..'9'} or s[i] == '.'): inc i
  try: (parseFloat(s[0 ..< i]), s[i .. ^1], true)
  except ValueError: (0.0, "", false)

proc foldArithmetic*(value: string): string =
  ## Stylus's `*` on a length and a number: `0.625em * 3` -> `1.875em`.
  ##
  ## THE CALL TRACE'S DEPTH INDENT. `calltrace.styl:669` is
  ## `margin-left: 0.625em * i` inside `for i in 0..100`, so every nested row's
  ## indentation is one of these products. With no arithmetic the emitted value
  ## was the literal `0.625em * i`, which a browser drops.
  ##
  ## Only `*`, only two operands, only when exactly one carries a unit — the
  ## whole of what the vendored set uses. Anything else is left for the
  ## emitted-value gate to report rather than guessed at. `calc()` is never
  ## entered: its `*` is already valid CSS and belongs to the browser.
  if "calc(" in value or '*' notin value: return value
  let parts = value.split('*')
  if parts.len != 2: return value
  let a = splitNumUnit(parts[0].strip)
  let b = splitNumUnit(parts[1].strip)
  if not a.ok or not b.ok: return value
  if a.unit.len > 0 and b.unit.len > 0: return value
  fmtNum(a.num * b.num) & (if a.unit.len > 0: a.unit else: b.unit)

proc substituteValue(value: string; env: Table[string, string];
                     bridge: OrderedTable[string, string]): string =
  ## `substitute`, with the `by-mode` build switch resolved first, and Stylus's
  ## unary minus folded AFTER substitution — the operand is a variable, so
  ## there is nothing to negate until it has been replaced.
  foldArithmetic(foldNegation(substitute(resolveByMode(value, env, bridge), env, bridge)))

proc residualToken(value: string): string =
  ## The first identifier left over that was meant to resolve, or "".
  var i = 0
  var quote = '\0'
  while i < value.len:
    let c = value[i]
    if quote != '\0':
      if c == quote: quote = '\0'
      inc i
      continue
    if c == '\'' or c == '"':
      quote = c
      inc i
      continue
    if c in IdentStart:
      var j = i
      while j < value.len and value[j] in IdentBody: inc j
      let id = value[i ..< j]
      if (j >= value.len or value[j] != '(') and looksLikeToken(id):
        return id
      i = j
      continue
    inc i
  ""

# ── urls ───────────────────────────────────────────────────────────────────
#
# See the header's "What happens to a `url()`": a vendored relative url is
# rewritten onto the published path of BlockTracer's own copy, and anything this
# module cannot place stops the build.

const VendoredAssetMarker = "public/resources/"
  ## The tail every vendored icon url shares. Matched as a SUBSTRING rather than
  ## by counting `../` segments on purpose: `button.styl` climbs three levels and
  ## `shared_widgets.styl` two, for the same directory, because the two sheets
  ## sit at different depths upstream. A rule written against the depth would
  ## have placed one sheet's icons and raised on the other's.

proc isOpaqueUrl(u: string): bool =
  ## A url a browser does not resolve against the stylesheet's own directory,
  ## and which therefore names no vendored file: site-absolute, scheme-
  ## qualified, protocol-relative, or a bare fragment.
  u.startsWith("/") or u.startsWith("//") or u.startsWith("#") or
    u.startsWith("data:") or u.startsWith("http://") or u.startsWith("https://")

proc placeUrl(payload, where: string;
              assetUrls: OrderedTable[string, string]): string =
  ## One `url()` payload → the payload to emit. Raises rather than returning the
  ## input unchanged for any relative url it cannot place.
  var quote = ""
  var u = payload.strip
  if u.len >= 2 and (u[0] == '"' or u[0] == '\'') and u[^1] == u[0]:
    quote = $u[0]
    u = u[1 ..< ^1]
  if u.len == 0 or isOpaqueUrl(u):
    return payload

  let at = u.find(VendoredAssetMarker)
  if at < 0:
    raise newException(StylError,
      where & ": relative url outside the vendored-asset shape: url(" & payload &
      ")\n(a relative url is resolved against /_a/<hash>.css, so it cannot " &
      "reach anything this site publishes. Either it names a vendored asset — " &
      "give it a `" & VendoredAssetMarker & "<group>/<file>` tail and an " &
      "`assetUrls` row — or ct_styl.nim must be widened to place it.)")
  # Everything before the marker must be `./` and `../` segments: that is what
  # makes the tail a path RELATIVE TO CodeTracer's `src/`, which is the one
  # reading under which `assetUrls`' keys mean anything.
  for seg in u[0 ..< at].split('/'):
    if seg.len > 0 and seg != "." and seg != "..":
      raise newException(StylError,
        where & ": url is not a plain ascent to CodeTracer's src/: url(" &
        payload & ")\n(the segment `" & seg & "` precedes `" &
        VendoredAssetMarker & "`, so the tail is not the upstream resource " &
        "path `assetUrls` is keyed on)")

  let key = u[at + VendoredAssetMarker.len .. ^1]
  if key notin assetUrls:
    raise newException(StylError,
      where & ": no vendored file for url(" & payload & ")\n(`" & key &
      "` is not in StylPort.assetUrls, which lists every CodeTracer resource " &
      "BlockTracer publishes a copy of. Vendor the file under " &
      "`client/src/assets/ct-icons/` and add its row — see that directory's " &
      "README. It is refused rather than passed through because a passed-" &
      "through url is the 404 this check exists to stop: 9 of 13 shipped " &
      "broken for exactly that reason.)")
  (if quote.len > 0: quote else: "\"") & assetUrls[key] &
    (if quote.len > 0: quote else: "\"")

proc rewriteUrls*(value, where: string;
                  assetUrls: OrderedTable[string, string]): string =
  ## Every `url(…)` in a declaration value, placed. `url` must be a function
  ## name here and not the tail of an identifier (`--my-url(` is not a url), so
  ## the match requires a non-identifier character before it.
  var i = 0
  while i < value.len:
    let hit = value.find("url(", i)
    if hit < 0:
      result.add value[i .. ^1]
      break
    let boundary = hit == 0 or value[hit - 1] notin IdentBody
    let close = value.find(')', hit + 4)
    if not boundary or close < 0:
      # Not a url function, or an unterminated one. The latter cannot be placed
      # and must not be guessed at; `isDeclaration` already accepted the line,
      # so leave the text alone and let the browser's own parser own it.
      result.add value[i .. hit + 3]
      i = hit + 4
      continue
    result.add value[i ..< hit]
    result.add "url("
    result.add placeUrl(value[hit + 4 ..< close], where, assetUrls)
    result.add ")"
    i = close + 1

# ── classification ─────────────────────────────────────────────────────────

proc isAssignment(s: string): bool =
  ## `NAME = value`, at any depth. Distinguished from a declaration by the `=`
  ## and from a selector by starting with an identifier.
  let eq = s.find('=')
  if eq <= 0: return false
  if eq + 1 < s.len and s[eq + 1] == '=': return false
  let name = s[0 ..< eq].strip
  name.len > 0 and name[0] in IdentStart and name.allCharsInSet(IdentBody)

const BuildConditions = {
  # BlockTracer is a WEBSITE, not CodeTracer's VS Code extension, so every
  # `IS_EXTENSION` arm resolves the same way on this side of the port. Naming
  # the flag here rather than assuming it keeps the decision reviewable: an arm
  # that starts mattering is a line to change, not a silent reinterpretation.
  "IS_EXTENSION": false,
}.toTable

proc conditionOf(s: string): tuple[ident: string, negated: bool, isCond: bool] =
  ## `if IS_EXTENSION` / `if !IS_EXTENSION`. Only the single-identifier form is
  ## recognised; anything richer raises at the call site rather than being
  ## guessed at, because a mis-evaluated condition silently emits the WRONG arm.
  var body = s.strip
  if not body.startsWith("if "): return ("", false, false)
  body = body[3 .. ^1].strip
  var negated = false
  if body.startsWith("!"):
    negated = true
    body = body[1 .. ^1].strip
  if body.len == 0: return ("", false, false)
  for c in body:
    if c notin {'A'..'Z', '_', '0'..'9'}: return ("", false, false)
  (body, negated, true)

proc isColonlessDeclaration(s: string): bool =
  ## Stylus lets a declaration omit its colon — `flex-basis 100%`. Four lines in
  ## `shared_widgets.styl` do; none of the other vendored files do.
  ##
  ## The test is only ever applied to a LEAF, and that is what makes it safe
  ## rather than a guess. A selector always introduces a block, and a selector
  ## with no block is already an error here — so a leaf that is not an
  ## assignment, a mixin call or an at-rule has nowhere else to be. The property
  ## shape is still required, so `div span` (a descendant selector someone left
  ## blockless) keeps raising instead of being emitted as `div:span`.
  let sp = s.find(' ')
  if sp <= 0: return false
  let prop = s[0 ..< sp]
  for c in prop:
    if c notin {'a'..'z', '-'}: return false
  s[sp + 1 .. ^1].strip.len > 0

proc isDeclaration(s: string): bool =
  ## `property: value`. A selector may also contain `:` (`&:hover`,
  ## `.lm_tabdropdown::before`, `table:has(…)`), so the test is that the text
  ## STARTS with a bare CSS property name and the colon carries a value.
  if s.endsWith(","): return false
  if s.len == 0 or s[0] notin {'a'..'z', 'A'..'Z', '-'}: return false
  var i = 0
  while i < s.len and (s[i] in IdentBody or s[i] == '-'): inc i
  if i >= s.len or s[i] != ':': return false
  # `&:hover` never reaches here; `td:hover` would, so require a value.
  s[i + 1 .. ^1].strip.len > 0

proc isMixinCall(s: string): bool =
  s.len > 2 and s[0] in {'a'..'z'} and s.endsWith(")") and
    '(' in s and ':' notin s[0 ..< s.find('(')]

# ── selector composition ───────────────────────────────────────────────────

proc forLoopOf(s: string): tuple[v: string, lo, hi: int, isLoop: bool] =
  ## `for i in 0..100` — the one loop form the vendored set uses
  ## (`calltrace.styl:665`, the call trace's depth indent).
  if not s.startsWith("for "): return ("", 0, 0, false)
  let inAt = s.find(" in ")
  if inAt < 0: return ("", 0, 0, false)
  let v = s[4 ..< inAt].strip
  let rng = s[inAt + 4 .. ^1].strip
  let dots = rng.find("..")
  if v.len == 0 or dots < 0: return ("", 0, 0, false)
  try:
    (v, parseInt(rng[0 ..< dots].strip), parseInt(rng[dots + 2 .. ^1].strip), true)
  except ValueError:
    ("", 0, 0, false)

proc interpolate(n: Node; v, value: string): Node =
  ## `{i}` -> the iteration's value, through the whole subtree. Stylus
  ## interpolation is textual and appears here only in selectors (`&-{i}`).
  result = Node(indent: n.indent, line: n.line,
                text: n.text.replace("{" & v & "}", value))
  for k in n.kids: result.kids.add interpolate(k, v, value)

proc splitSelectorGroup*(s: string): seq[string] =
  ## A selector line's TOP-LEVEL comma members.
  ##
  ## THIS WAS NOT DONE AND IT SHIPPED. Stylus lets a nested rule's selector
  ## group sit on one line — `calltrace.styl:214` writes
  ## `.call-text:focus-visible, .toggle-call:focus-visible` — and the whole
  ## line was carried as ONE member, so `compose` prefixed the parent onto the
  ## first and nothing onto the rest:
  ##
  ##   .calltrace-view .call-text:focus-visible, .toggle-call:focus-visible
  ##
  ## The second member lost `.calltrace-view`. That is not a near miss: it
  ## matches in places the rule was never meant to reach, and it carries one
  ## class less of specificity, so where it IS meant to apply another rule now
  ## outranks it. Nine such lines are in the vendored set, in the Call Trace,
  ## the Event Log, the State pane and the menus.
  ##
  ## Commas inside `:not(…)`, `:is(…)` and `[attr="a,b"]` are NOT separators,
  ## so depth and quotes are tracked rather than a bare `split(',')`.
  var depth = 0
  var quote = '\0'
  var cur = ""
  for c in s:
    if quote != '\0':
      cur.add c
      if c == quote: quote = '\0'
    elif c == '\'' or c == '"':
      quote = c; cur.add c
    elif c == '(' or c == '[':
      inc depth; cur.add c
    elif c == ')' or c == ']':
      dec depth; cur.add c
    elif c == ',' and depth == 0:
      if cur.strip.len > 0: result.add cur.strip
      cur = ""
    else:
      cur.add c
  if cur.strip.len > 0: result.add cur.strip

proc compose(parents, kids: seq[string]): seq[string] =
  ## Stylus nesting: `&` is the parent, otherwise a descendant.
  if parents.len == 0:
    return kids
  for p in parents:
    for k in kids:
      if '&' in k: result.add k.replace("&", p)
      else: result.add p & " " & k

# ── the emitter ────────────────────────────────────────────────────────────

proc collectVars*(sources: seq[StylSource];
                  bridge: OrderedTable[string, string]): Table[string, string] =
  ## Pre-pass over every input, so a constant declared in one file is visible
  ## in another. `codetracer.styl` gets the same effect from its import order;
  ## BlockTracer consumes a SUBSET of that list, so ordering alone would leave
  ## `PANEL_INSET` (button.styl) unreachable from `golden_layout.styl`.
  for src in sources:
    for (_, raw) in stripComments(src.text):
      let body = raw.strip
      if indentOf(raw) == 0 and body.isAssignment:
        let eq = body.find('=')
        result[body[0 ..< eq].strip] = body[eq + 1 .. ^1].strip

proc mixinName(s: string): string =
  ## `segmented-tab()` → `segmented-tab`. Arguments are deliberately not
  ## handled: every mixin in the vendored set is parameterless, and a
  ## parameterised one must raise rather than silently expand with the wrong
  ## body.
  s[0 ..< s.find('(')].strip

proc collectMixins*(sources: seq[StylSource]): Table[string, seq[Node]] =
  ## Pre-pass over every input, for the same reason `collectVars` has one: a
  ## mixin defined in one file is called from another, and BlockTracer consumes
  ## a SUBSET of `codetracer.styl`'s import list, so source order alone would
  ## leave a definition unreachable from its call.
  ##
  ## A DEFINITION IS A MIXIN CALL THAT HAS A BLOCK. `segmented-tabs()` at column
  ## zero with children is a definition; the same text as a leaf is a call. The
  ## parser cannot tell them apart by spelling, only by whether a block follows,
  ## which is exactly how Stylus reads them too.
  for src in sources:
    for n in buildTree(src):
      if n.kids.len > 0 and n.text.isMixinCall:
        result[mixinName(n.text)] = n.kids

proc emitBlock(nodes: seq[Node]; parents: seq[string]; src: StylSource;
               port: StylPort; env: var Table[string, string];
               rep: var StylReport; body: var string;
               mixins: Table[string, seq[Node]]; expandDepth = 0)

proc emitBlock(nodes: seq[Node]; parents: seq[string]; src: StylSource;
               port: StylPort; env: var Table[string, string];
               rep: var StylReport; body: var string;
               mixins: Table[string, seq[Node]]; expandDepth = 0) =
  ## One indentation level. Declarations at this level belong to `parents`;
  ## nested blocks recurse. Emitted depth-first in source order, which is what
  ## keeps CSS's cascade identical to the Stylus output's.
  var group: seq[string]
  var decls = ""

  # A template rather than a closure: `body` is a `var` parameter, which Nim
  # will not let a closure capture.
  template flushDecls() =
    if decls.len > 0 and parents.len > 0:
      body.add parents.join(",") & "{" & decls & "}\n"
      inc rep.rules
    decls = ""

  for n in nodes:
    if n.text.startsWith("@import"):
      continue
    let qualified = src.origin.rsplit('/', 1)[^1] & ": " & n.text
    if qualified in port.dropRules or n.text in port.dropRules:
      let why = if qualified in port.dropRules: port.dropRules[qualified]
                else: port.dropRules[n.text]
      rep.dropped.add src.origin & ":" & $n.line & "  " & n.text & " — " & why
      continue
    if n.text.startsWith("@keyframes ") and n.kids.len > 0:
      # The stops are emitted as rules into a buffer of their own and joined
      # onto ONE line, which is what `scoped` recognises and leaves alone.
      flushDecls()
      var stops = ""
      for stop in n.kids:
        emitBlock(stop.kids, @[stop.text], src, port, env, rep, stops, mixins,
                  expandDepth)
      body.add n.text & "{" & stops.replace("\n", "") & "}\n"
      inc rep.rules
      continue
    if n.text.startsWith("@media ") and n.kids.len > 0:
      # The opening and closing lines are passed through by `scoped`; the rules
      # between them are scoped like every other rule. A `@media` nested in a
      # rule keeps that rule's selector, as Stylus bubbles it.
      flushDecls()
      body.add n.text & "{\n"
      emitBlock(n.kids, parents, src, port, env, rep, body, mixins, expandDepth)
      body.add "}\n"
      continue
    if n.text.startsWith("@"):
      raise newException(StylError,
        src.origin & ":" & $n.line & ": at-rule outside the subset: " & n.text &
        "\n(add it to dropRules with a reason, or widen ct_styl.nim)")
    if n.kids.len == 0 and n.text.isAssignment:
      let eq = n.text.find('=')
      env[n.text[0 ..< eq].strip] = n.text[eq + 1 .. ^1].strip
      continue
    if n.kids.len > 0 and n.text.isMixinCall:
      # A DEFINITION, not a rule. Emitting it would produce a CSS selector
      # spelled `segmented-tabs()`, which matches nothing and silently replaces
      # the styling the call site expected.
      continue
    if n.kids.len == 0 and n.text.isMixinCall:
      let name = mixinName(n.text)
      if '(' in n.text and n.text[n.text.find('(') + 1 .. ^2].strip.len > 0:
        raise newException(StylError,
          src.origin & ":" & $n.line & ": parameterised mixin outside the subset: " &
          n.text & "\n(every mixin in the vendored set is parameterless; widen ct_styl.nim)")
      if name notin mixins:
        raise newException(StylError,
          src.origin & ":" & $n.line & ": mixin call outside the subset: " &
          n.text & "\n(drop the enclosing rule with a reason, or widen ct_styl.nim)")
      # A mixin may call a mixin — `segmented-tabs()` calls `segmented-tab()` —
      # so expansion recurses, and a cycle would recurse forever. The bound is
      # a diagnosis, not a silent truncation.
      if expandDepth >= 8:
        raise newException(StylError,
          src.origin & ":" & $n.line & ": mixin expansion too deep at " & n.text &
          " (cycle?)")
      # Flush first so the cascade matches Stylus: declarations written BEFORE
      # the call, then the mixin's, then those after. Three rules with the same
      # selector in that order resolve identically to one rule in that order.
      flushDecls()
      emitBlock(mixins[name], parents, src, port, env, rep, body, mixins,
                expandDepth + 1)
      continue
    if n.kids.len == 0 and n.text.isDeclaration:
      let colon = n.text.find(':')
      let prop = n.text[0 ..< colon].strip
      var value = n.text[colon + 1 .. ^1].strip
      # Stylus tolerates a trailing `;`; several vendored rules carry one.
      value = value.strip(leading = false, chars = {';', ' '})
      var subbed = substituteValue(value, env, port.bridge)
      # The residue check runs BEFORE the aliases, and the order is load-bearing.
      # `residualToken` looks for an identifier that was MEANT to resolve, and
      # one of its shapes is SCREAMING_CASE — which a replacement's own text can
      # accidentally be. An alias produces FINAL CSS, not a stylus identifier, so
      # it must not be re-examined: measured on a probe whose replacement was the
      # literal `MONO`, which the check then read as an unresolved constant and
      # dropped the whole declaration.
      let residue = residualToken(subbed)
      if residue.len > 0:
        rep.unresolved.add src.origin & ":" & $n.line & "  " & prop & ": " &
          value & "  (" & residue & ")"
        continue
      for spelling, replacement in port.literalAliases.pairs:
        if spelling in subbed: subbed = subbed.replace(spelling, replacement)
      # LAST, so the emitted url is the one `rewriteUrls` decided and not
      # something a literal alias then rewrote underneath it.
      subbed = rewriteUrls(subbed, src.origin & ":" & $n.line, port.assetUrls)
      decls.add prop & ":" & subbed & ";"
      inc rep.declarations
      continue
    block forLoop:
      let f = forLoopOf(n.text)
      if not f.isLoop: break forLoop
      # A LOOP IS NOT A SELECTOR, and flattening it into one is what shipped:
      # `[data-register="debugger"] .expanded for i in 0..100-{i}` reached
      # production, matching nothing, with `margin-left:0.625em * i` inside it.
      # So all 101 `.expanded-N` rules were missing and the call trace's nested
      # rows had no depth indent at all. Same failure shape as the conditional
      # below, which is why it is answered the same way.
      if f.hi - f.lo > 1024:
        raise newException(StylError,
          src.origin & ":" & $n.line & ": loop range outside the subset: " & n.text)
      flushDecls()
      for iter in f.lo .. f.hi:
        env[f.v] = $iter
        var kids: seq[Node]
        for k in n.kids: kids.add interpolate(k, f.v, $iter)
        emitBlock(kids, parents, src, port, env, rep, body, mixins, expandDepth)
      env.del f.v
      continue

    block conditional:
      let c = conditionOf(n.text)
      if not c.isCond: break conditional
      # A CONDITIONAL IS NOT A SELECTOR. Flattened into one it emitted
      # `[data-register="debugger"] if IS_EXTENSION .component-container-html`,
      # which matches nothing — and the arm that SHOULD have applied was lost
      # with it. That is the silent divergence this module's header refuses.
      if c.ident notin BuildConditions:
        raise newException(StylError,
          src.origin & ":" & $n.line & ": unknown build condition: " & n.text &
          "\n(add it to BuildConditions with a value, or widen ct_styl.nim)")
      let taken = BuildConditions[c.ident] != c.negated
      rep.dropped.add src.origin & ":" & $n.line & "  " & n.text & " — " &
        (if taken: "taken" else: "not taken") & " (" & c.ident & " is " &
        $BuildConditions[c.ident] & " for this build)"
      if taken:
        # Inline the arm at THIS level: its declarations belong to the
        # enclosing rule, exactly as Stylus would place them.
        emitBlock(n.kids, parents, src, port, env, rep, body, mixins, expandDepth)
      continue
    if n.kids.len == 0 and n.text.isColonlessDeclaration:
      let sp = n.text.find(' ')
      let prop = n.text[0 ..< sp]
      let value = n.text[sp + 1 .. ^1].strip.strip(leading = false, chars = {';', ' '})
      var subbed = substituteValue(value, env, port.bridge)
      let residue = residualToken(subbed)
      if residue.len > 0:
        rep.unresolved.add src.origin & ":" & $n.line & "  " & prop & ": " &
          value & "  (" & residue & ")"
        continue
      for spelling, replacement in port.literalAliases.pairs:
        if spelling in subbed: subbed = subbed.replace(spelling, replacement)
      # LAST, so the emitted url is the one `rewriteUrls` decided and not
      # something a literal alias then rewrote underneath it.
      subbed = rewriteUrls(subbed, src.origin & ":" & $n.line, port.assetUrls)
      decls.add prop & ":" & subbed & ";"
      inc rep.declarations
      continue
    # A selector line: either a group member, or the head of a nested block.
    #
    # BUT FIRST: ANYTHING NOT RECOGNISED ABOVE REACHES HERE AND BECOMES A
    # SELECTOR, and that silence is how the `for` loop shipped. Every other
    # construct outside the subset raises — an at-rule, a parameterised mixin,
    # an unknown mixin, an unknown build condition — and a statement this
    # transpiler has simply never heard of was the one case that did not. It
    # was emitted as `.expanded for i in 0..100-{i}`: a selector matching
    # nothing, carrying declarations that were therefore lost, and no gate had
    # a reason to look at it.
    #
    # A CSS selector cannot contain `..` (a Stylus range), `{` or `}`
    # (unresolved interpolation), and does not begin with a Stylus keyword.
    # Each of those is a construct this port does not implement, so each is a
    # refusal with a name rather than a rule that quietly matches nothing.
    for residue in ["..", "{", "}"]:
      if residue in n.text:
        raise newException(StylError,
          src.origin & ":" & $n.line & ": unsupported stylus construct in a " &
          "selector position: " & n.text & "\n(`" & residue & "` cannot occur " &
          "in a CSS selector — implement it in ct_styl.nim, or drop the rule " &
          "with a reason)")
    for kw in ["for ", "each ", "return ", "unless ", "while "]:
      if n.text.startsWith(kw):
        raise newException(StylError,
          src.origin & ":" & $n.line & ": stylus `" & kw.strip &
          "` outside the subset: " & n.text &
          "\n(implement it in ct_styl.nim, or drop the rule with a reason)")
    for member in splitSelectorGroup(n.text.strip(leading = false, chars = {',', ' '})):
      group.add member
    if n.kids.len > 0:
      flushDecls()
      emitBlock(n.kids, compose(parents, group), src, port, env, rep, body,
                mixins, expandDepth)
      group = @[]

  if group.len > 0:
    raise newException(StylError,
      src.origin & ": selector with no block: " & group.join(" / "))
  flushDecls()

proc transpile*(sources: seq[StylSource]; port: StylPort;
                rep: var StylReport): string =
  ## Every vendored `.styl` in `codetracer.styl`'s own import order, one CSS
  ## string, each file preceded by a provenance comment naming its upstream
  ## path. The comment is the rule-by-rule trace the port is required to keep:
  ## rules appear in source order below their origin, so any rule here can be
  ## found upstream by reading down from the header.
  var env = collectVars(sources, port.bridge)
  let mixins = collectMixins(sources)
  for src in sources:
    var roots = buildTree(src)
    if src.definitionsOnly:
      var kept: seq[Node]
      for n in roots:
        if n.text in src.emitOnly: kept.add n
      if kept.len != src.emitOnly.len:
        raise newException(StylError, src.origin & ": emitOnly names " &
          $src.emitOnly.len & " rule(s) and " & $kept.len & " are in the sheet")
      roots = kept
    var body = ""
    emitBlock(roots, @[], src, port, env, rep, body, mixins)
    if body.len > 0:
      result.add "\n/* ── ported verbatim from CodeTracer " & src.origin &
        " ── */\n"
      result.add body

proc scoped*(css, scope: string): string =
  ## Prefix every selector in an emitted rule list. Applied after emission
  ## rather than during it so the scope is provably uniform: one pass, one
  ## place, nothing nested can escape it.
  if scope.len == 0: return css
  for line in css.splitLines:
    if line.len == 0: continue
    if line.startsWith("/*") or line.startsWith(" ") or line.startsWith("@") or
        line == "}":
      # A comment, a continuation, an at-rule's own line (`@keyframes` is one
      # whole line; `@media` opens a block whose rules are scoped below) or the
      # `}` that closes a `@media`.
      result.add line & "\n"
      continue
    let brace = line.find('{')
    if brace < 0:
      result.add line & "\n"
      continue
    let sels = line[0 ..< brace].split(',')
    result.add sels.mapIt(scope & " " & it.strip).join(",")
    result.add line[brace .. ^1] & "\n"
