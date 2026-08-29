## Turning a source line into classified spans, at static-export time.
##
## ## Why there is a lexer here at all
##
## `source_document.nim` reserved this seam and stated the blocker: highlighting
## means tokenising per language, and a lexer per language is the dependency
## shape (Monaco, Shiki, tree-sitter-wasm) the static route refuses. Three facts
## decide how it is filled:
##
##   * **There is no Noir tree-sitter grammar.** `src/db-backend/Cargo.toml`
##     pins twenty-two grammars — Solidity, Cairo, Move-on-Aptos, Sway, Cadence,
##     Leo, Aiken, Circom, Rust, C, C++, Go, Python, Ruby, Nim, D, Pascal, bash,
##     JS and more — and Noir is not among them. Noir is the language of the only
##     real trace this repository has.
##   * **tree-sitter is native-only here anyway.** The grammars sit behind the
##     `syntax-highlight` cargo feature, whose own comment says it is disabled
##     for WASM builds because "the C grammars cannot be cross-compiled".
##   * **The page ships no JavaScript.** Whatever classifies a token has to do it
##     during `nim c -r src/static_export.nim` and emit the result as markup.
##
## So the tokeniser is Nim, it runs at export time, and its output is data that
## `components/debugger.nim` renders as `<span>`s inside the existing `<code>`.
##
## ## Why not `flow_layout.tokenizeSourceExpressions`
##
## CodeTracer's `viewmodel/viewmodels/flow_layout.nim` has a tokeniser with a
## `FlowTokenLanguage` **profile** — deliberately a profile rather than a `Lang`
## enum, so a consumer can describe its own language and `common_lang`/`std/os`
## stay out of the SDK graph. Its docstring even anticipates this caller: "A
## consumer that wants Noir or Rust builds its own profile — which is the point
## of the profile existing."
##
## The profile IDEA is adopted below, and credited. The CODE is not imported,
## for two reasons that are about this repository rather than about that module:
##
##   * **It is not a highlighter.** `FlowSourceToken` is `(expression, column)`
##     with no kind. It extracts identifiers to hang inline value labels on:
##     keywords are *dropped*, string interiors are *skipped*, and there is no
##     comment, number, operator or punctuation handling at all. Every part of
##     the job below — the kinds, the comment rules, the numeric and string
##     forms — would still have to be written on top of it.
##   * **Importing it would put the debugger on the client's Nim path.**
##     `client/nim.cfg` carries `src`, `../src`, isonim and nim-everywhere and
##     nothing else; `just export`, `just test-debug-route` and
##     `just test-viewmodels` all compile with no CodeTracer path, and their
##     recipes say so ("Hermetic: no debugger on the Nim path"). That property
##     is defended by CI and is worth more than seventy-five lines of state
##     machine. Reaching for `flow_layout` would also mean bumping
##     `ci/embed-sdk-pin.env`, because the module postdates the current pin.
##
## ## The seam: a second language is data
##
## `LanguageProfile` is the whole of what this module knows about a language —
## character sets, word lists, comment and string delimiters. Adding Solidity or
## Move is a `LanguageProfile` literal in `KnownLanguages` below and nothing
## else. What is NOT claimed is that such a profile exists today: `KnownLanguages`
## has exactly one entry, Noir, because Noir is the language this repository can
## actually demonstrate against a real trace. A file whose language has no
## profile renders as plain text — see `highlightLines`.
##
## Note that CodeTracer's desktop app does not have a Noir lexer either. Both its
## Monaco path and its diff view substitute Rust (`if lang == LangNoir: lang =
## LangRust`), which is a good approximation rather than a shrug, but it is still
## an approximation. The profile below is Noir's own: `Field`, the sized integer
## types, and the `f"…"` format strings that `shield.nr` is full of.

import std/strutils

type
  TokenKind* = enum
    ## What a span of source text IS, as far as colour is concerned.
    ##
    ## Eight kinds, and the list is closed on purpose. It is the set the desktop
    ## theme gives a distinct colour to and that a profile can identify without a
    ## parser: everything here is decidable by a lexer, and nothing here needs to
    ## know what a name resolves to. `tkFunction` is the one kind that reads a
    ## neighbouring character rather than the token itself, and it is documented
    ## where it is decided.
    tkPlain = "plain"
      ## Whitespace, and identifiers with nothing more specific to say about
      ## them. Rendered WITHOUT a span — see `components/debugger.nim`.
    tkComment = "comment"
    tkKeyword = "keyword"
    tkType = "type"
    tkFunction = "function"
    tkString = "string"
    tkNumber = "number"
    tkPunctuation = "punctuation"

  SourceToken* = object
    ## One classified run of characters from one line.
    ##
    ## `text` is the ORIGINAL characters, unescaped and unmodified. The renderer
    ## escapes; this module must not, or the two would each half-escape.
    kind*: TokenKind
    text*: string

  LanguageProfile* = object
    ## Everything the lexer knows about one language.
    ##
    ## A profile rather than an enum, following `FlowTokenLanguage`'s reasoning
    ## and for the same payoff: BlockTracer will need Solidity, Move and Cadence,
    ## and a profile makes each of those a data row instead of a branch in a
    ## `case`. `names` is matched case-insensitively so a bundle that says
    ## `Noir`, `noir` or `nr` all land on the same profile.
    names*: seq[string]
      ## Every spelling that selects this profile. Empty means "unknown
      ## language", which is what `profileFor` returns when nothing matches.
    identifierStart*: set[char]
      ## Characters that may BEGIN an identifier. Digits are deliberately not
      ## here even though they may continue one.
    identifierBody*: set[char]
      ## Characters that may CONTINUE an identifier. Must include
      ## `identifierStart` or `x1` will lex as two tokens.
    keywords*: seq[string]
    types*: seq[string]
      ## Named types the language gives a distinct colour. A word list and not a
      ## capitalisation rule: `Field` is a type and `Prover` is not, and no
      ## amount of case analysis can tell a lexer which is which.
    functionKeywords*: seq[string]
      ## Words after which the next identifier NAMES a function — `fn` in Noir.
      ## This is what lets a declaration be coloured like a call without the
      ## trailing `(` a call has.
    lineComment*: string
      ## Empty disables line comments entirely.
    blockOpen*, blockClose*: string
      ## Empty disables block comments. These are the only construct that
      ## carries state ACROSS lines; see `highlightLines`.
    stringDelimiters*: set[char]
    stringPrefixes*: seq[string]
      ## Identifiers that, when immediately followed by a string delimiter, are
      ## part of the literal rather than a name before it — Noir's `f"…"`.
    escape*: char
      ## The in-string escape character. `'\0'` disables escaping.

const
  Digits = {'0'..'9'}
  Whitespace = {' ', '\t'}

func isKnown*(p: LanguageProfile): bool =
  ## Whether this profile can classify anything at all.
  ##
  ## The unknown profile is the zero value, so a caller that forgets to check
  ## gets "no tokens" — which the renderer draws as plain text — rather than a
  ## confident mis-tokenisation.
  p.names.len > 0

# ---------------------------------------------------------------------------
# The language registry
# ---------------------------------------------------------------------------

const NoirProfile* = LanguageProfile(
  names: @["noir", "nr"],
  identifierStart: {'a'..'z', 'A'..'Z', '_'},
  identifierBody: {'a'..'z', 'A'..'Z', '0'..'9', '_'},
  # `true` and `false` sit with the keywords rather than with the numbers.
  # Either is defensible; what is not defensible is letting them fall through
  # to `tkPlain`, which is what a list that forgot them would do.
  keywords: @[
    "as", "assert", "assert_eq", "break", "comptime", "constrain", "continue",
    "contract", "crate", "dep", "else", "false", "fn", "for", "global", "if",
    "impl", "in", "let", "mod", "mut", "pub", "quote", "return", "self",
    "Self", "struct", "super", "trait", "true", "type", "unconstrained",
    "unsafe", "use", "where", "while"],
  types: @[
    "Field", "bool", "str", "fmtstr", "BoundedVec", "Option", "String", "Vec",
    "u1", "u8", "u16", "u32", "u64", "u128",
    "i1", "i8", "i16", "i32", "i64"],
  functionKeywords: @["fn"],
  lineComment: "//",
  blockOpen: "/*",
  blockClose: "*/",
  stringDelimiters: {'"'},
  stringPrefixes: @["f", "r"],
  escape: '\\')

const KnownLanguages* = [NoirProfile]
  ## Every language BlockTracer can genuinely highlight today.
  ##
  ## One entry. The array is the seam — a second language is another
  ## `LanguageProfile` literal here — but an array with a Solidity profile in it
  ## that nothing has ever been rendered through would be a claim of support
  ## this repository cannot show, so there is not one.

func profileFor*(language: string): LanguageProfile =
  ## The profile for a language name, or the unknown profile.
  ##
  ## Unknown is a VALUE and not an exception: an unrecognised language is the
  ## ordinary case for a published source bundle from a chain we do not yet
  ## lex, and the correct response is plain text rather than a failed export.
  let want = language.strip().toLowerAscii()
  if want.len == 0: return
  for p in KnownLanguages:
    for n in p.names:
      if n == want: return p

func fileExtension(path: string): string =
  ## The extension, lowercased, without the dot — or "" if there is none.
  var dot = -1
  for i in countdown(path.len - 1, 0):
    if path[i] == '/': break
    if path[i] == '.':
      dot = i
      break
  if dot < 0 or dot == path.len - 1: "" else: path[dot + 1 .. ^1].toLowerAscii()

func profileForDocument*(path, language: string): LanguageProfile =
  ## The profile for one FILE of a source bundle.
  ##
  ## **The extension decides, and the bundle's declared language is only the
  ## fallback.** A published bundle carries one `language` for the whole
  ## bundle — Source-Resolution §5 puts it on the bundle, not on each entry —
  ## but a bundle is not all one language. The demo's own is the proof: the
  ## `zk_shields` bundle declares `noir` and contains `Nargo.toml` and
  ## `Prover.toml` beside the two `.nr` files. Trusting the declared language
  ## per file rendered `[package]` with Noir's punctuation colours and
  ## `initial_shield = "10000"` as a Noir string literal — a manifest wearing
  ## source highlighting, which is precisely the confident nonsense this
  ## module refuses to produce.
  ##
  ## So an extension that names no profile yields NO profile, rather than
  ## falling through to the bundle's language. `.toml` is not "unknown, try
  ## Noir"; it is "known not to be Noir". The declared language is consulted
  ## only for a path with no extension at all, where it is the sole evidence.
  let ext = fileExtension(path)
  if ext.len > 0: profileFor(ext) else: profileFor(language)

# ---------------------------------------------------------------------------
# The lexer
# ---------------------------------------------------------------------------

func matchesAt(line: string; i: int; pat: string): bool =
  pat.len > 0 and i + pat.len <= line.len and line[i ..< i + pat.len] == pat

func classifyWord(p: LanguageProfile; word: string; line: string; after: int;
                  prevKeyword: string): TokenKind =
  ## What an identifier is, given the word, what follows it, and the last
  ## keyword seen on the line.
  ##
  ## The order matters. Keywords and types are decided by the word alone, so
  ## they are checked first and a language that lists `Field` as a type can
  ## never have it coloured as a call. Only then does the lexer look outward.
  for k in p.keywords:
    if k == word: return tkKeyword
  for t in p.types:
    if t == word: return tkType
  for f in p.functionKeywords:
    if f == prevKeyword: return tkFunction
  # A call: the next non-space character opens an argument list. This is the
  # one lookahead in the lexer, and it is the reason `println` colours as a
  # function while `damage` does not, with no symbol table anywhere.
  var j = after
  while j < line.len and line[j] in Whitespace: inc j
  if j < line.len and line[j] == '(': return tkFunction
  tkPlain

func highlightLine(p: LanguageProfile; line: string;
                   inBlockComment: var bool): seq[SourceToken] =
  ## One line, given whether a block comment is open when it starts.
  ##
  ## INVARIANT, and the property the tests assert: the concatenation of every
  ## returned token's `text` equals `line`, exactly. Every character of the
  ## source belongs to exactly one token — whitespace included, as `tkPlain`.
  ## A lexer that dropped or rewrote characters would render source that is not
  ## the source, which is a worse failure than no highlighting at all.
  var i = 0
  var prevKeyword = ""

  # A template rather than a nested proc: a closure cannot capture `result`
  # without violating memory safety, and the alternative — building a local seq
  # and copying it out — would allocate twice for every line in the file.
  template emit(k: TokenKind; s: string) =
    block:
      let piece = s
      if piece.len > 0:
        # Coalesce adjacent runs of the same kind so the markup does not carry
        # a span per character for a run of punctuation.
        if result.len > 0 and result[^1].kind == k:
          result[^1].text.add piece
        else:
          result.add SourceToken(kind: k, text: piece)

  while i < line.len:
    # ── an open block comment swallows everything until it closes ──────────
    if inBlockComment:
      var j = i
      while j < line.len and not matchesAt(line, j, p.blockClose): inc j
      if j < line.len:
        j += p.blockClose.len
        inBlockComment = false
      emit(tkComment, line[i ..< j])
      i = j
      continue

    let c = line[i]

    # ── whitespace ────────────────────────────────────────────────────────
    if c in Whitespace:
      var j = i
      while j < line.len and line[j] in Whitespace: inc j
      emit(tkPlain, line[i ..< j])
      i = j
      continue

    # ── comments, line then block ─────────────────────────────────────────
    if matchesAt(line, i, p.lineComment):
      emit(tkComment, line[i .. ^1])
      i = line.len
      continue

    if matchesAt(line, i, p.blockOpen):
      inBlockComment = true
      emit(tkComment, line[i ..< i + p.blockOpen.len])
      i += p.blockOpen.len
      continue

    # ── identifiers, and the string prefixes that look like them ──────────
    if c in p.identifierStart:
      var j = i
      while j < line.len and line[j] in p.identifierBody: inc j
      let word = line[i ..< j]
      var isPrefix = false
      if j < line.len and line[j] in p.stringDelimiters:
        for sp in p.stringPrefixes:
          if sp == word: isPrefix = true
      if isPrefix:
        # `f"…"` — the prefix belongs to the literal, not to the name before
        # it. Fall through to the string scanner starting at `i` so the prefix
        # and the quoted body arrive as ONE token.
        discard
      else:
        let kind = classifyWord(p, word, line, j, prevKeyword)
        emit(kind, word)
        prevKeyword = (if kind == tkKeyword: word else: "")
        i = j
        continue

    # ── strings, including any prefix immediately before the quote ─────────
    block stringScan:
      var j = i
      while j < line.len and line[j] in p.identifierBody and
            line[j] notin p.stringDelimiters: inc j
      if j >= line.len or line[j] notin p.stringDelimiters:
        break stringScan
      let quote = line[j]
      inc j
      while j < line.len:
        if p.escape != '\0' and line[j] == p.escape and j + 1 < line.len:
          inc j, 2
          continue
        if line[j] == quote:
          inc j
          break
        inc j
      # An unterminated literal ends at the line. Noir has no multi-line
      # string, so carrying the state forward would mis-colour the whole rest
      # of the file on one stray quote.
      emit(tkString, line[i ..< j])
      prevKeyword = ""
      i = j
      continue

    # ── numbers ───────────────────────────────────────────────────────────
    if c in Digits:
      var j = i
      if matchesAt(line, i, "0x") or matchesAt(line, i, "0b") or
         matchesAt(line, i, "0o"):
        j = i + 2
        while j < line.len and
              (line[j] in {'0'..'9', 'a'..'f', 'A'..'F', '_'}): inc j
      else:
        while j < line.len and line[j] in {'0'..'9', '_'}: inc j
        # A decimal point counts only when a digit follows it, so `0..8`
        # lexes as number, range operator, number rather than one bad float.
        if j + 1 < line.len and line[j] == '.' and line[j + 1] in Digits:
          inc j
          while j < line.len and line[j] in {'0'..'9', '_'}: inc j
      emit(tkNumber, line[i ..< j])
      prevKeyword = ""
      i = j
      continue

    # ── everything else is punctuation ────────────────────────────────────
    emit(tkPunctuation, $c)
    prevKeyword = ""
    inc i

func highlightLines*(lines: openArray[string];
                     p: LanguageProfile): seq[seq[SourceToken]] =
  ## Every line's tokens, in order, with block-comment state carried between
  ## them.
  ##
  ## Returns an EMPTY seq for an unknown language — not a seq of plain tokens.
  ## The renderer distinguishes the two: no tokens means "render the line as
  ## the single text node it was before this module existed", which is the
  ## honest output for a file nothing here can lex. `Page-Descriptions` §14's
  ## fidelity ladder needs the same behaviour one level up, where there is no
  ## source at all; both end at plain text rather than at a guess.
  if not p.isKnown: return
  var inBlockComment = false
  for line in lines:
    result.add highlightLine(p, line, inBlockComment)
