## The instruction listing — what the Code pane shows when nobody published
## source for the code a transaction ran.
##
## ## What was wrong, and it was not a styling gap
##
## A real chain recording on this site is rung 3: the Aztec node serves
## `ContractClassPublic`, which carries packed bytecode and no debug symbols, no
## file map and no source text, so no step resolves to a line. The pane's answer
## to that was two paragraphs — one of which described an instruction-level
## recording *in words* and was then followed by no instructions. The recording
## has 208 steps on the transaction the defect was filed against, every one of
## them carrying a program counter, and the pane whose whole question is "where
## is this stopped" had nothing on screen to be stopped at.
##
## The floor of the fidelity ladder is a real rung and not a failure, which the
## prose already said. This module is the part that makes it true of the markup:
## the coordinates the recording actually has, rendered as rows, with the current
## one marked by the same mechanism a source line is marked by.
##
## ## It is the floor, not a replacement for source
##
## Source may resolve for some of these. `artifactHash` on the chain exists so a
## client can verify an artifact fetched OFF chain, and verified artifacts
## demonstrably exist — so fidelity is a per-transaction fact and not a constant
## of the chain. Nothing here assumes otherwise: this listing is built only where
## `srcUnverified` was decided, and a transaction that resolves to source takes
## the source path exactly as it always did. The two coexist and the page says
## which one it is on.
##
## ## Why the rows are `SourceLine`s
##
## Because every mark the pane already knows how to draw is attached to one, and
## an instruction listing that re-implemented them would be an imitation that
## drifts. The current-position fill, the `▶` in its own `.p` cell, the
## `aria-current` on the row, the stable per-row anchor, the windowing at the
## position, the inlined island hydration re-renders from — all of it is the
## source path's machinery, reached by handing it different rows. In particular
## the position glyph lives in `.p` and the branch glyphs live in `.m`, which is
## the separation a sibling landed to stop `⊙` displacing `▶`; going through the
## same renderer is what makes it impossible to reintroduce here.
##
## ## What is NOT claimed
##
## `notTaken` and `ran` are left empty on every row. They are the source pane's
## claim about a branch ARM — "this region was evaluated and not taken", drawn
## as a dimmed block with `⊘` — and this listing has no arms, no regions and no
## passes. Empty is not "did not run": `SourceLine.notTaken`'s own header says
## empty means nothing is claimed, and nothing is what should be claimed here.
## A control transfer is stated where it belongs instead — in the instruction's
## own text, as the destination the recording jumped to.
##
## The loop rail is absent for the same reason and by the same rule that already
## produced that outcome: `flow_view.applyFlow` refuses to attach one below
## source level, because a rail's whole content is "this loop, at this line".

import std/[json, strutils, unicode]
import ./avm_opcodes
import ./session_view

# `ListingPath` MOVED DOWN into `session_view`, and is re-exported here so no
# call site moved — the same route `truncHash` and `Copyable` took, for the same
# reason.
#
# It is the identity of a listing DOCUMENT, and the pane type lives one module
# down. `components/debugger.renderSource` has to decide whether the rows in
# front of it are a listing or source, and it could not name this constant
# without importing this producer. A renderer importing a producer to ask what
# it is looking at is the wrong direction; the answer belongs on the vocabulary
# both of them already share. Its own reasoning went with it, unchanged.
export session_view.ListingPath

const
  ListingLanguage* = "avm"

  NoProgramCounter* = -1
    ## The `pc` of a step that carries a SOURCE POSITION instead of a counter.
    ##
    ## A recording may position some of its steps and not others — 459 steps
    ## across two contracts at two fidelities is the first one this tree
    ## publishes — and on a positioned step the container spends its `line` field
    ## on the source line, so there is no offset to publish. The producer
    ## (`tools/chain/derive-instructions.mjs`) writes this rather than a null,
    ## which `intColumn` would discard, or the line number, which would read as an
    ## offset and be one.
    ##
    ## `-1` is impossible as a bytecode offset, so nothing can mistake it for one.
    ## Everything that does ARITHMETIC on a counter tests for it by name:
    ## `hexWidth` (a sentinel must not decide the column's width), the
    ## `destinationSuffix` (a difference against a sentinel is not a jump), and
    ## `avm_opcodes.explainsProgramCounters` — that last one matters most, because
    ## one sentinel differenced against a real counter is one mismatch, and one
    ## mismatch withdraws the opcode names from the WHOLE recording.
    ##
    ## The row still exists, and that is the point. Row `n` is tick `n`, so the
    ## listing has a row for every step the recording took whether or not it can
    ## put a counter on it — which is what lets the pane mark where the session is
    ## at the 373 steps the source cannot cover.

  ListingNoPcCell* = "—"
    ## What a sentinel row shows where a counter would be. An em dash and not a
    ## `0x????` or a blank: blank reads as a column that failed to render, and a
    ## hex-shaped placeholder reads as an address. This row's coordinate is in the
    ## source pane, and the dash says the counter is not this row's to give.

# THE ROWS ARE NUMBERED IN THE SESSION'S OWN COORDINATE, and there is only one.
#
# `rrTicks` is what the engine counts, what `data-step` carries, what `?t=`
# anchors a share link to, what a call-trace row hands back on click, and what
# the toolbar displays before and after hydration. It starts at 0: a hydrated
# session lands at tick 0 and its first step takes it to 1, and on the source
# path that landing resolves to the program's FIRST line, so tick 0 is a real
# position and not "no position".
#
# So row `i` is tick `i`, zero-based, and the gutter shows the number a reader
# can paste into a URL. The alternative — numbering rows 1..N as "the n-th
# recorded step" — reads more naturally and is wrong in a way that shows: the
# position head would say "stopped at step 1" while the row highlighted was the
# second, on every hydrated page, because the head states the tick.
#
# One consequence is worth naming rather than absorbing. `demo_session
# .entryStepWithin` lands a trace shorter than the fixture's step on `steps`
# itself — "the trace's own last step" — which under this numbering is one past
# the end, because a recording of 108 steps has ticks 0..107. That is a
# pre-existing off-by-one in a landing rule, invisible while nothing rendered a
# row to compare it against. `withInstructionListing` resolves the landing
# against the listing, which is the only place that knows how long the recording
# is, and corrects the session's own coordinate with it — so the page never
# reports a position outside its own recording, which is an invariant this
# repository already asserts.

type
  InstructionStep* = object
    ## One recorded step, as the recording wrote it.
    pc*: int          ## the program counter — an offset into the executed
                      ## bytecode, or `NoProgramCounter` on a step whose
                      ## coordinate is a source position instead
    opcode*: int      ## the opcode NUMBER the recorder wrote; never a name
    l2Gas*: int       ## the L2 gas meter's reading at this step
    context*: int     ## which execution context this step ran in

  InstructionListing* = object
    ## One recording's instruction stream, plus what may honestly be said of it.
    steps*: seq[InstructionStep]
    objectPath*: string
      ## The path the RECORDER interned for the executed object. Displayed as
      ## the name of a bytecode object and never as a source file — it is not
      ## one, and the whole point of this pane is that there is no source file.
    isa*: string
      ## The instruction set the recording declares. Empty means it declared
      ## none, and an unrecognised one is why `named` can be false without any
      ## mismatch having been found.
    hasGas*: bool
    check*: OpcodeTableCheck
    named*: bool
      ## Whether mnemonics may be shown for this recording. `check.explains`, and
      ## a listing may be `false` here and still render every program counter —
      ## losing the names is not losing the listing.

func stepCount*(l: InstructionListing): int = l.steps.len

func hasListing*(l: InstructionListing): bool = l.steps.len > 0

func hasProgramCounter*(s: InstructionStep): bool = s.pc != NoProgramCounter

func counterSteps*(l: InstructionListing): int =
  ## How many of the rows carry a real program counter. Equal to `stepCount` on
  ## every recording that positions nothing, which is all but two of the ones
  ## this tree publishes; smaller on a partly-positioned one, and what the
  ## caption states so a reader is not left to count dashes.
  for s in l.steps:
    if s.hasProgramCounter: inc result

func partlyPositioned*(l: InstructionListing): bool =
  ## Does this listing describe a recording at TWO fidelities?
  ##
  ## Both sides non-zero, which is the same definition
  ## `tools/journeys/lib/corpus.mjs` selects the class on and the same one
  ## `session_view.positionedSteps` records: a listing with no sentinel is an
  ## ordinary instruction-level recording, and one that is all sentinel is
  ## refused by the producer before it reaches a file.
  l.steps.len > 0 and l.counterSteps > 0 and l.counterSteps < l.steps.len

# ---------------------------------------------------------------------------
# decoding what the tree publishes
# ---------------------------------------------------------------------------

func intColumn(node: JsonNode; name: string; want: int): seq[int] =
  ## One published column, or an empty seq.
  ##
  ## A column of the wrong LENGTH is discarded rather than padded or truncated.
  ## The columns are parallel by construction on the producing side, so a short
  ## one means the payload is not what this reader thinks it is, and zipping it
  ## against the others would attribute one step's gas to another step.
  let col = node{name}
  if col == nil or col.kind != JArray or col.len != want: return @[]
  for v in col:
    if v.kind != JInt: return @[]
    result.add v.getInt

proc decodeInstructionListing*(node: JsonNode): InstructionListing =
  ## The published `instructions.json`, back into a listing.
  ##
  ## A payload this reader does not understand yields an EMPTY listing rather
  ## than a partial one or an exception. The caller's fallback is the pane the
  ## route has always served — the stated reason and the supply-sources action —
  ## which is a correct page, so there is nothing to be gained by failing louder
  ## and a whole transaction page to lose.
  if node == nil or node.kind != JObject: return
  # THE VERSION IS READ WHERE ONE IS DECLARED, AND ONLY THERE.
  #
  # `/2` widened the `pc` column: an entry may be `NoProgramCounter`, meaning the
  # step's coordinate is a source position and not an offset. Every `/1` payload
  # is a valid `/2` payload with no sentinel in it, so both are read the same way
  # — but a version this reader has NOT been taught could widen the column again,
  # and the failure mode of guessing is a listing that renders a new sentinel as a
  # program counter. A payload declaring no schema at all is still read, because
  # the structural checks below are what actually decide whether the columns are
  # parallel; the guard is against a version that would pass them and mean
  # something else.
  let schema = node{"schema"}
  if schema != nil and schema.kind == JString and
     schema.getStr notin ["avm-instructions/1", "avm-instructions/2"]: return
  let pcs = node{"pc"}
  if pcs == nil or pcs.kind != JArray or pcs.len == 0: return
  let n = pcs.len
  let pc = intColumn(node, "pc", n)
  let op = intColumn(node, "op", n)
  if pc.len != n or op.len != n: return
  let l2 = intColumn(node, "l2", n)
  let ctx = intColumn(node, "ctx", n)
  result.objectPath = node{"path"}.getStr("")
  result.isa = node{"isa"}.getStr("")
  result.hasGas = l2.len == n
  for i in 0 ..< n:
    result.steps.add InstructionStep(
      pc: pc[i], opcode: op[i],
      l2Gas: (if result.hasGas: l2[i] else: 0),
      context: (if ctx.len == n: ctx[i] else: 0))
  result.check = explainsProgramCounters(pc, op, ctx)
  # THE NAMES ARE EARNED PER RECORDING. `isa` alone would be the recording
  # asserting its own decodability; the check is the table predicting this
  # recording's program counters and being right about every one it predicted.
  # A recording from an instruction set this table is not fails it, which is the
  # case that made the check worth writing rather than asserting.
  result.named = result.isa == "aztec-avm" and result.check.explains

# ---------------------------------------------------------------------------
# the rows
# ---------------------------------------------------------------------------

func cells(s: string): int =
  ## How many CHARACTER CELLS a column value occupies, which is not `len`.
  ##
  ## The destination suffix carries `→`, three bytes and one glyph, so padding
  ## computed from `len` short-changed exactly the rows that had one and left the
  ## gas column two cells left of where it sat on every other row — visible as a
  ## ragged edge on the jumps, which are the rows a reader scans for.
  ##
  ## `runeLen` and not a display-width table: everything this listing can emit is
  ## ASCII plus the one arrow, all of which are single-cell in a monospace face.
  ## A width table would be machinery for a case that cannot arise here.
  s.runeLen

func hexWidth(l: InstructionListing): int =
  ## How many hex digits every program counter is padded to.
  ##
  ## ONE width for the whole listing, taken from the largest counter in it, so
  ## the mnemonic column starts at the same character on every row. Padding each
  ## counter to its own width would left-align a column of addresses, which is
  ## the one column a reader scans vertically.
  ##
  ## SENTINEL ROWS ARE NOT COUNTERS AND ARE SKIPPED. It takes a maximum, so a
  ## negative sentinel could never have widened the column — but "the largest
  ## counter" has to be read off the counters, and taking the argument as the
  ## whole listing is what makes that true by construction rather than by the
  ## sentinel's sign. A listing with no counter at all is impossible (the producer
  ## refuses to write one), and the floor of 4 answers it if one ever arrives.
  result = 4
  var maxPc = 0
  for s in l.steps:
    if s.hasProgramCounter and s.pc > maxPc: maxPc = s.pc
  var v = maxPc
  var digits = 1
  while v >= 16:
    v = v shr 4
    inc digits
  if digits > result: result = digits

func pcText*(pc, width: int): string =
  ## `0x0011`. Lower case, because a program counter is an address and this
  ## product spells addresses in lower case everywhere else.
  ##
  ## A sentinel gets the dash, padded to the same cell so the column stays a
  ## column. `toHex(-1, w)` would render `0xffff` — a plausible address, in the
  ## one column a reader trusts to be an address — which is why this is here and
  ## not left to the caller to remember.
  if pc == NoProgramCounter:
    let cell = 2 + width
    return ListingNoPcCell & spaces(max(0, cell - ListingNoPcCell.runeLen))
  "0x" & toHex(pc, width).toLowerAscii

func opcodeText*(l: InstructionListing; op: int): string =
  ## The instruction, as this listing may honestly name it.
  ##
  ## `opcode 39` and not `UNKNOWN_39`: a name-shaped string is read as a name,
  ## and the whole reason this branch exists is that no name has been earned.
  if l.named:
    let name = avmOpcodeName(op)
    if name.len > 0: return name
  "opcode " & $op

func destinationSuffix*(l: InstructionListing; i, pcw: int): string =
  ## ` → 0x0041`, when this step transferred control somewhere other than the
  ## next instruction.
  ##
  ## Derived from where the recording WENT — `pc[i+1]` — and not from the
  ## instruction's operand, so it states an observed fact and needs no operand
  ## decoding. A step whose successor is the fall-through gets nothing: the row
  ## below it already says where control went, and an arrow on every row would
  ## make the arrows that matter invisible.
  ##
  ## The last step has no successor and gets nothing, which is right: a recording
  ## ends where it ends and this pane does not know what the VM did next.
  ##
  ## An unknown opcode gets nothing either, and that is the conservative
  ## direction: without a length there is no fall-through to compare against, so
  ## every row would sprout an arrow and the listing would claim a jump at every
  ## step.
  ##
  ## A SENTINEL AT EITHER END GETS NOTHING, and that is the conservative
  ## direction again. `pc[i+1] - pc[i]` is the whole derivation, and a step that
  ## published no counter cannot be either side of it: differencing against the
  ## sentinel would put an arrow on every row at the boundary between the two
  ## fidelities and name `—` as a destination. What that step transferred control
  ## to is a source line, and the source pane is where it is stated.
  if i + 1 >= l.steps.len: return ""
  let here = l.steps[i]
  let next = l.steps[i + 1]
  if not here.hasProgramCounter or not next.hasProgramCounter: return ""
  if next.context != here.context:
    return " → context " & $next.context & " " & pcText(next.pc, pcw)
  if not knownAvmOpcode(here.opcode): return ""
  if next.pc == here.pc + AvmInstructionSet[here.opcode].size: return ""
  " → " & pcText(next.pc, pcw)

proc listingDocument*(l: InstructionListing; currentStep: int): SourceDocument =
  ## The listing, as rows the source renderer can draw.
  ##
  ## Row `n` is tick `n` — see the note above the type declarations. It is the
  ## coordinate the rest of the session already speaks: what the toolbar counts,
  ## what `.srcpos` states, what `data-step` carries and what a share link
  ## anchors to. A row numbered by program counter would be a second coordinate
  ## on a page that has one, and the two would disagree the moment a program
  ## counter repeated — which is what a loop is.
  ##
  ## ## The three columns
  ##
  ##     0x0011  INTERNALCALL → 0x0041      9
  ##     ^pc     ^instruction               ^L2 gas
  ##
  ## The PROGRAM COUNTER, because it is the coordinate the recording carries and
  ## the thing the pane was accused of describing and not showing.
  ##
  ## The INSTRUCTION, named when `named` was earned and numbered otherwise, plus
  ## the destination when this step transferred control somewhere other than the
  ## next instruction. The destination is read off the NEXT step's program
  ## counter — it is where the recording actually went, not where the operand
  ## says it would go, so it needs no operand decoding and cannot disagree with
  ## the row below it.
  ##
  ## The L2 GAS the meter moved between the previous step and this one. Two
  ## recorded numbers subtracted, and deliberately described that way rather than
  ## as "what this instruction cost": the recording states a reading per step and
  ## does not state which side of the instruction the reading was taken. The
  ## arithmetic is the same either way and the attribution is not, so only the
  ## arithmetic is claimed. (What it looks like: under this attribution `SSTORE`
  ## comes out at ~33,140 and `SET_8` at 27 across the published containers,
  ## which is the shape the world-state opcodes should have.) The FIRST row has
  ## no previous reading and shows nothing, rather than a `0` that would read as
  ## a free instruction.
  ##
  ## Everything is padded to a column width computed from the whole listing, and
  ## rendered as ONE text node — no tokens. `renderSource` emits a token-free
  ## line as plain text, which is what a listing nothing here can lex must be.
  result.path = ListingPath
  result.language = ListingLanguage
  if l.steps.len == 0: return

  let pcw = hexWidth(l)

  # The column widths, over the WHOLE listing and in one pass. The destination
  # suffix is measured here too, not added after: a suffix appended past the
  # measurement would push the gas column right on exactly the rows that have
  # one, which is the ragged edge the padding exists to prevent.
  var opWidth = 0
  var gasWidth = 0
  for i, s in l.steps:
    let w = cells(opcodeText(l, s.opcode) & destinationSuffix(l, i, pcw))
    if w > opWidth: opWidth = w
    if l.hasGas and i > 0:
      let d = ($(s.l2Gas - l.steps[i - 1].l2Gas)).len
      if d > gasWidth: gasWidth = d

  for i, s in l.steps:
    var text = pcText(s.pc, pcw) & "  "
    let instr = opcodeText(l, s.opcode) & destinationSuffix(l, i, pcw)
    text.add instr
    if l.hasGas:
      text.add spaces(max(1, opWidth - cells(instr)) + 1)
      let gas = (if i == 0: "" else: $(s.l2Gas - l.steps[i - 1].l2Gas))
      text.add spaces(max(0, gasWidth - gas.len)) & gas
    let n = i
    result.lines.add SourceLine(
      number: n,
      # Trailing padding stripped. The gas column is right-aligned, so only the
      # first row — which has no previous reading and therefore no gas — ends in
      # it, and a single row whose text is longer than it looks is a row that
      # would report a different `.len` to anything measuring the listing.
      text: text.strip(leading = false, trailing = true),
      anchor: lineAnchor(ListingPath, n),
      # EVERY ROW IS A STEP THE RECORDING TOOK, which is exactly what `executed`
      # means on the source path — "the trace visited this". It is uniform here
      # because the listing is the visit list, and the alternative was a blank
      # gutter that would have made the same channel mean two different things
      # on two pages.
      executed: true,
      current: n == currentStep)

proc listingCaption*(l: InstructionListing): string =
  ## The one line above the rows that says what they are.
  ##
  ## It names the columns, because a bare grid of hex would otherwise have to be
  ## guessed at, and it names the OBJECT the counters are offsets into — which is
  ## the fact that distinguishes "this listing is unpositioned" from "this listing
  ## is unlabelled".
  if l.steps.len == 0: return ""
  var parts = @[$l.steps.len & " recorded steps, 0–" & $(l.steps.len - 1) &
                " as the session counts them"]
  # THE COUNTER COLUMN NAMES ITS OWN COVERAGE WHERE IT IS NOT COMPLETE, because
  # a reader scanning a column of `—` is owed the reason before they invent one.
  # It is the same measurement the producer published (`counters`), stated in the
  # place a reader meets the dashes rather than only in the page's prose.
  if l.partlyPositioned:
    # PARENTHESISED, because the separator between the column names is already an
    # em dash-ish `·` list and the sentinel's own glyph is an em dash: run
    # together they read as `of them — — where`, which looks like a typo in the
    # one line that explains what the dashes below mean.
    parts.add "program counter on " & $l.counterSteps & " of them (" &
              ListingNoPcCell & " where the step resolves to a source line instead)"
  else:
    parts.add "program counter"
  parts.add (if l.named: "opcode" else: "opcode number")
  if l.hasGas: parts.add "L2 gas since the previous step"
  result = parts.join(" · ")
  if l.objectPath.len > 0:
    result.add " — counters are offsets into " & l.objectPath
