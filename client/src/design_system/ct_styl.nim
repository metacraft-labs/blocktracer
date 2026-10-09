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
##
## NOT in the subset, and each one raises: mixin DEFINITIONS and calls,
## `@media`/`@keyframes`/`@supports`, `if`/`else`/`for`/`unless`, `@extend`,
## interpolation `{…}`, property-without-colon form. Where a vendored file uses
## one, the enclosing rule is named in `dropRules` with a reason.
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
      ## Upstream selector line → why BlockTracer does not emit it.
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
  var roots: seq[Node]
  var stack: seq[Node]
  for (lineNo, raw) in stripComments(src.text):
    let body = raw.strip
    if body.len == 0: continue
    let ind = indentOf(raw)
    let n = Node(indent: ind, line: lineNo, text: body)
    while stack.len > 0 and stack[^1].indent >= ind:
      discard stack.pop
    if stack.len == 0: roots.add n
    else: stack[^1].kids.add n
    stack.add n
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
    if n.text in port.dropRules:
      rep.dropped.add src.origin & ":" & $n.line & "  " & n.text & " — " &
        port.dropRules[n.text]
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
      var subbed = substitute(value, env, port.bridge)
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
      var subbed = substitute(value, env, port.bridge)
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
    group.add n.text.strip(leading = false, chars = {',', ' '})
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
    var body = ""
    emitBlock(buildTree(src), @[], src, port, env, rep, body, mixins)
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
    if line.startsWith("/*") or line.startsWith(" "):
      result.add line & "\n"
      continue
    let brace = line.find('{')
    if brace < 0:
      result.add line & "\n"
      continue
    let sels = line[0 ..< brace].split(',')
    result.add sels.mapIt(scope & " " & it.strip).join(",")
    result.add line[brace .. ^1] & "\n"
