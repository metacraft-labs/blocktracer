## Where a file's conditionals are, and which lines each arm owns.
##
## This is the structural half of "highlight the branch that was taken and dim
## the ones that were not". The *evidential* half — deciding, from the recorded
## steps, which arms actually ran — is `flow_view.notTakenPasses`, and the split
## is deliberate: this module knows nothing about a trace and cannot express an
## opinion about execution, so a bug here can lose a conditional but can never
## invent a claim about one.
##
## ## Why a second reader of the source, and not the trace
##
## CodeTracer's desktop app gets branch structure from **tree-sitter**:
## `expr_loader.extract_branches` walks the AST, records each arm's
## `header_line`/`code_first_line`/`code_last_line`, and wires every arm's
## siblings into `Branch.opposite`. `load_branch_for_position` then marks the arm
## the debugger stepped into `Taken` and every sibling `NotTaken`.
##
## None of that is available here. The grammars are behind a native-only cargo
## feature (`syntax-highlight`, "the C grammars cannot be cross-compiled"), there
## is no Noir grammar among the twenty-two pinned, and the served page ships no
## JavaScript — the same three facts that made `source_highlight` a Nim lexer
## rather than a Monaco or a tree-sitter dependency. So the structure is
## recovered from the token stream that lexer already produces.
##
## That buys one property worth naming: **braces inside strings and comments
## cannot fool the matcher**, because it never sees characters. It matches
## `tkPunctuation` tokens, and `highlightLines` has already decided that a `{` in
## `f"…{x}…"` is part of a `tkString`.
##
## ## Every arm is an INTERIOR, and never a header
##
## An arm's region is the lines strictly between its `{` and its `}`. The header
## is excluded on purpose, and the reason is a defect in the desktop
## implementation this one declines to inherit: desktop keys `BranchesTaken` on
## `header_line`, so an `else if` whose condition WAS evaluated and came out
## false is painted with the same "not taken" background as an arm that was
## never reached. Evaluating a condition is executing that line. Only the
## statements inside the braces can be claimed not to have run.
##
## It also makes the claim uniform: "these statements did not run" is true of a
## plain `else` body and of an `else if` body in exactly the same way, so there
## is one sentence for the reader and one rule for the code.
##
## ## Refusal is a first-class outcome
##
## A construct this module cannot read to the end is DROPPED, not approximated.
## A one-line `if (c) { x; }` has no interior and yields nothing; an unbalanced
## file yields nothing from the point the balance broke; a language with no
## `LanguageProfile` yields nothing at all. The cost of a refusal is an undimmed
## branch, which is the state the pane was in before this existed. The cost of a
## guess is a region dimmed on the strength of a brace the lexer misread — a
## confident, wrong statement about the execution, on the pane whose whole claim
## is that it does not make those.

import std/strutils

import ./source_highlight

type
  BranchArm* = object
    ## One arm of a conditional: `if (c) { … }`, `else if (c) { … }`, `else { … }`.
    headerLine*: int
      ## The line the arm's keyword is on — the `if` of an `if`/`else if`, or the
      ## `else` of a plain `else`. Used as EVIDENCE that the chain was entered
      ## (a step here means the condition was evaluated); never dimmed.
    firstLine*, lastLine*: int
      ## The interior, inclusive. `firstLine > lastLine` never occurs: an arm
      ## with no interior is refused rather than emitted empty, so a consumer
      ## cannot iterate an inverted range.

  Conditional* = object
    ## One `if` chain, with every arm of it.
    ##
    ## The chain and not the individual `if` is the unit, because the whole
    ## claim rests on the arms being MUTUALLY EXCLUSIVE: exactly one of them runs
    ## per evaluation. That is what lets "arm 2 ran" prove "arm 1 did not", which
    ## is the only inference here strong enough to dim anything.
    headerLine*: int          ## the governing `if`
    exhaustive*: bool
      ## The chain ends in a plain `else`, so one arm MUST run whenever the
      ## chain is entered.
      ##
      ## It changes what silence means, which is why it is carried rather than
      ## inferred at the use site. In a non-exhaustive chain, "no arm recorded a
      ## step" is a fact about the program — every condition was false. In an
      ## exhaustive one it is a fact about the RECORDING — some arm ran and was
      ## not instrumented — and nothing may be claimed from it.
    arms*: seq[BranchArm]

  Token = object
    line: int
    kind: TokenKind
    text: string

func flatten(lines: seq[seq[SourceToken]]): seq[Token] =
  ## The per-line token seqs as one stream, carrying line numbers.
  ##
  ## Whitespace, comments and `tkPlain` runs that are only whitespace are
  ## dropped: they can never be part of a construct and keeping them would make
  ## every "the next token is …" test in the parser restate the skip.
  ##
  ## **A punctuation run is split back into single characters**, and that is not
  ## a detail. `highlightLine` coalesces adjacent tokens of one kind so the
  ## markup does not carry a span per character — which means the `)` and the
  ## `{` of `if (c){` arrive as ONE `tkPunctuation` token spelled `){`, and a
  ## matcher comparing token text to `"{"` finds no brace anywhere in the file
  ## and silently reports that it contains no conditionals. It did, exactly, on
  ## the first run of this module against the demo source: every claim in it
  ## became vacuously true and every test over it would have passed.
  for i, lineTokens in lines:
    for t in lineTokens:
      if t.kind == tkComment: continue
      if t.kind == tkPlain and t.text.strip().len == 0: continue
      if t.kind == tkPunctuation:
        for c in t.text:
          result.add Token(line: i + 1, kind: tkPunctuation, text: $c)
      else:
        result.add Token(line: i + 1, kind: t.kind, text: t.text)

func isPunct(t: Token; s: string): bool =
  t.kind == tkPunctuation and t.text == s

func isWord(t: Token; s: string): bool =
  t.kind == tkKeyword and t.text == s

func matchingBrace(tokens: seq[Token]; open: int): int =
  ## The index of the `}` closing the `{` at `open`, or `-1`.
  ##
  ## `-1` for an unbalanced file rather than a clamp to the end, because the two
  ## are different and only one of them may produce a region. A construct whose
  ## end cannot be located has no interior anybody can name.
  var depth = 0
  for i in open ..< tokens.len:
    if isPunct(tokens[i], "{"): inc depth
    elif isPunct(tokens[i], "}"):
      dec depth
      if depth == 0: return i
  -1

func openingBrace(tokens: seq[Token]; start: int): int =
  ## The `{` that opens the body of the arm whose keyword sits just before
  ## `start`, or `-1` when this construct is not one this module can read.
  ##
  ## The scan is BOUNDED. A brace-less `if cond expr`, a macro, or a lexer that
  ## mis-classified the condition all end up walking to the end of the file
  ## looking for a `{` that belongs to some other construct entirely — and would
  ## then hand back a region that has nothing to do with this conditional. The
  ## terminators below are the tokens that mean "the condition is over and there
  ## was no block": a statement end, a block end, or the next construct's
  ## keyword.
  ##
  ## And the `{` has to be at bracket depth ZERO. A brace nested inside the
  ## condition's own parentheses or brackets belongs to something in the
  ## condition — a closure body, a struct literal — and is not this arm's block.
  ## Taking it would put the arm's interior inside the condition, so the region
  ## dimmed would be an expression that WAS evaluated.
  var depth = 0
  for i in start ..< tokens.len:
    let t = tokens[i]
    if isPunct(t, "(") or isPunct(t, "["): inc depth
    elif isPunct(t, ")") or isPunct(t, "]"): dec depth
    elif isPunct(t, "{") and depth == 0: return i
    elif isPunct(t, ";") or isPunct(t, "}"): return -1
    elif t.kind == tkKeyword and t.text in ["fn", "else", "for", "while", "let"]:
      return -1
  -1

func armAt(tokens: seq[Token]; headerLine, openIndex: int): (BranchArm, int) =
  ## The arm whose body opens at `openIndex`, and the index of its `}`.
  ##
  ## Returns an arm with `firstLine > lastLine` for a body with no interior —
  ## `{ x; }` on one line, or `{` and `}` on adjacent lines. The caller refuses
  ## the whole conditional on it rather than emitting a region of no lines,
  ## because an arm whose statements share a line with a sibling's cannot be
  ## dimmed without dimming code that DID run.
  let close = matchingBrace(tokens, openIndex)
  if close < 0: return (BranchArm(headerLine: headerLine, firstLine: 1, lastLine: 0), -1)
  (BranchArm(headerLine: headerLine,
             firstLine: tokens[openIndex].line + 1,
             lastLine: tokens[close].line - 1), close)

func overlaps(a, b: BranchArm): bool =
  a.firstLine <= b.lastLine and b.firstLine <= a.lastLine

func chainAt(tokens: seq[Token]; ifIndex: int): (Conditional, seq[int]) =
  ## The whole `if` / `else if` / `else` chain starting at `ifIndex`.
  ##
  ## The second result is the indices of the `if` keywords this chain CONSUMED
  ## as continuations, so the caller's linear scan does not re-enter an
  ## `else if` as a chain of its own — which would emit a second, shorter
  ## conditional over the same arms and let one evaluation be counted twice.
  ##
  ## An empty `arms` means "refused": see the module header.
  var consumed: seq[int] = @[]
  var conditional = Conditional(headerLine: tokens[ifIndex].line)
  var i = ifIndex
  var headerLine = tokens[ifIndex].line
  while true:
    let open = openingBrace(tokens, i + 1)
    if open < 0: return (Conditional(), consumed)
    let (arm, close) = armAt(tokens, headerLine, open)
    if close < 0 or arm.firstLine > arm.lastLine: return (Conditional(), consumed)
    for existing in conditional.arms:
      if overlaps(existing, arm): return (Conditional(), consumed)
    conditional.arms.add arm
    # `else` has to be the very next token after the `}`. Anything else ends the
    # chain — including a second `}`, which is how a nested conditional at the
    # end of an enclosing block stops here instead of adopting the enclosing
    # block's `else` as its own arm.
    if close + 1 >= tokens.len or not isWord(tokens[close + 1], "else"): break
    if close + 2 < tokens.len and isWord(tokens[close + 2], "if"):
      consumed.add close + 2
      headerLine = tokens[close + 2].line
      i = close + 2
      continue
    # A plain `else`: its body opens next, it has no condition of its own, and
    # it closes the chain.
    let elseOpen = openingBrace(tokens, close + 2)
    if elseOpen < 0: return (Conditional(), consumed)
    let (elseArm, elseClose) = armAt(tokens, tokens[close + 1].line, elseOpen)
    if elseClose < 0 or elseArm.firstLine > elseArm.lastLine:
      return (Conditional(), consumed)
    for existing in conditional.arms:
      if overlaps(existing, elseArm): return (Conditional(), consumed)
    conditional.arms.add elseArm
    conditional.exhaustive = true
    break
  (conditional, consumed)

func findConditionals*(lines: openArray[string];
                       profile: LanguageProfile): seq[Conditional] =
  ## Every readable `if` chain in a file, outermost-first in source order.
  ##
  ## An unknown language yields NOTHING, on the same rule `highlightLines`
  ## follows one layer down: a file this repository cannot lex is a file whose
  ## braces it cannot locate, and locating them anyway — by counting `{`
  ## characters, say — is how a `{` inside `f"…{x}…"` becomes a branch region.
  ## Noir is the only profile that exists today, so this is also the honest
  ## reason a Solidity bundle gets no dimming rather than a guessed one.
  if not profile.isKnown: return
  let tokens = flatten(highlightLines(lines, profile))
  var skip: seq[int] = @[]
  for i, t in tokens:
    if not isWord(t, "if"): continue
    if i in skip: continue
    let (conditional, consumed) = chainAt(tokens, i)
    for c in consumed: skip.add c
    if conditional.arms.len > 0: result.add conditional
