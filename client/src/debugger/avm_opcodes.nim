## The Aztec AVM instruction set, as far as an instruction LISTING needs it: a
## name per opcode number, and the number of bytes that opcode occupies.
##
## ## Why a table here at all, when the recording already carries the number
##
## A chain recording writes an opcode NUMBER per step. A number is honest and
## unreadable; `SSTORE` is readable and is an interpretation — of that number
## against a version of the instruction set. This repository has a standing rule
## about the difference (`source_document.nim`: "Applying Noir's lexer to a
## Solidity file … would produce confident nonsense, which is worse than plain
## text because it looks authoritative"), and a mnemonic table is the same hazard
## with a different surface: an opcode enum that gained a member upstream would
## shift every later name by one and the listing would go on rendering
## confidently.
##
## So the table is not trusted. It is CHECKED, per recording, by
## `explainsProgramCounters` below, and a listing whose recording the table
## cannot explain renders numbers.
##
## ## The check, and why it is evidence rather than a formality
##
## Every entry carries `size`, the instruction's encoded length in bytes with the
## opcode byte included. A recording's program counters are offsets into the
## bytecode, so for two consecutive steps that did not branch and did not change
## context, `pc[i+1] - pc[i]` must equal `size[op[i]]` — and it must do so for
## every such pair, for opcodes of six different lengths, with no fitting
## parameter anywhere. A table that named the wrong instructions would have to
## agree with the recorder's own program counters by accident, several hundred
## times, on a stream neither side produced from the other.
##
## Measured on the eight real chain containers this repository publishes: 2026 of
## 2026 non-branching same-context transitions matched, zero mismatches, across
## the 27 distinct opcodes those executions used. The check is re-run at build
## time on whatever is published, so that number is a record of what was true and
## not the reason the names are shown.
##
## ## Provenance
##
## Names and their order are `enum Opcode` from
## `yarn-project/simulator/src/public/avm/serialization/instruction_serialization.ts`
## in `AztecProtocol/aztec-packages` at `3a68d68ac29aaf04fc6251c80a8eb874043cb260`.
## Sizes are the sum of that instruction's `wireFormat` operand widths from the
## same tree (`UINT8` 1, `UINT16` 2, `UINT32` 4, `UINT64` 8, `UINT128` 16, `FF`
## 32, `TAG` 1) — the format arrays include the opcode byte as their first
## `UINT8`, so a size here is the whole instruction.
##
## Kept as one table with both columns because they are read together and a
## mnemonic whose size lived elsewhere could be renamed without the check that
## licenses it noticing.

type
  AvmInstruction* = object
    name*: string
    size*: int
      ## Encoded length in bytes, opcode byte included.
    branches*: bool
      ## Whether this instruction may set the program counter to something other
      ## than "the next instruction". The check below cannot say anything about a
      ## transition out of one of these, so it does not try.

func ins(name: string; size: int; branches = false): AvmInstruction =
  AvmInstruction(name: name, size: size, branches: branches)

const AvmInstructionSet* = [
  # Compute
  ins("ADD_8", 5), ins("ADD_16", 8),
  ins("SUB_8", 5), ins("SUB_16", 8),
  ins("MUL_8", 5), ins("MUL_16", 8),
  ins("DIV_8", 5), ins("DIV_16", 8),
  ins("FDIV_8", 5), ins("FDIV_16", 8),
  ins("EQ_8", 5), ins("EQ_16", 8),
  ins("LT_8", 5), ins("LT_16", 8),
  ins("LTE_8", 5), ins("LTE_16", 8),
  ins("AND_8", 5), ins("AND_16", 8),
  ins("OR_8", 5), ins("OR_16", 8),
  ins("XOR_8", 5), ins("XOR_16", 8),
  ins("NOT_8", 4), ins("NOT_16", 6),
  ins("SHL_8", 5), ins("SHL_16", 8),
  ins("SHR_8", 5), ins("SHR_16", 8),
  ins("CAST_8", 5), ins("CAST_16", 7),
  # Execution environment
  ins("GETENVVAR_16", 5),
  ins("CALLDATACOPY", 8),
  ins("SUCCESSCOPY", 4),
  ins("RETURNDATASIZE", 4),
  ins("RETURNDATACOPY", 8),
  # Control flow
  ins("JUMP_32", 5, branches = true),
  ins("JUMPI_32", 8, branches = true),
  ins("INTERNALCALL", 5, branches = true),
  ins("INTERNALRETURN", 1, branches = true),
  # Memory
  ins("SET_8", 5), ins("SET_16", 7), ins("SET_32", 9),
  ins("SET_64", 13), ins("SET_128", 21), ins("SET_FF", 37),
  ins("MOV_8", 4), ins("MOV_16", 6),
  # World state
  ins("SLOAD", 8), ins("SSTORE", 6),
  ins("NOTEHASHEXISTS", 8), ins("EMITNOTEHASH", 4),
  ins("NULLIFIEREXISTS", 6), ins("EMITNULLIFIER", 4),
  ins("L1TOL2MSGEXISTS", 8),
  ins("GETCONTRACTINSTANCE", 7),
  ins("EMITPUBLICLOG", 6),
  ins("SENDL2TOL1MSG", 6),
  # External calls
  ins("CALL", 13, branches = true),
  ins("STATICCALL", 13, branches = true),
  ins("RETURN", 6, branches = true),
  ins("REVERT_8", 4, branches = true),
  ins("REVERT_16", 6, branches = true),
  # Misc
  ins("DEBUGLOG", 12),
  # Gadgets
  ins("POSEIDON2", 6),
  ins("SHA256COMPRESSION", 8),
  ins("KECCAKF1600", 6),
  ins("ECADD", 13),
  # Conversion
  ins("TORADIXBE", 13),
]

func knownAvmOpcode*(op: int): bool =
  ## Whether the table has an entry for this number at all.
  op >= 0 and op < AvmInstructionSet.len

func avmOpcodeName*(op: int): string =
  ## The mnemonic, or `""` for a number this table does not cover.
  ##
  ## Empty and not a placeholder such as `UNKNOWN`: the caller has to render
  ## something else for it, and a name-shaped string would be rendered as a name.
  if knownAvmOpcode(op): AvmInstructionSet[op].name else: ""

type
  OpcodeTableCheck* = object
    ## What `explainsProgramCounters` found. A bool would answer the question and
    ## lose the evidence — how many transitions were actually checkable is the
    ## difference between "the table explains this recording" and "this recording
    ## branched so often that nothing was tested".
    checked*: int      ## transitions the table made a prediction about
    matched*: int      ## …of which the recording agreed
    skipped*: int      ## branches, context changes, and unknown opcodes
    unknown*: int      ## steps whose opcode number the table does not cover

func explains*(c: OpcodeTableCheck): bool =
  ## Whether this recording's mnemonics may be shown.
  ##
  ## Three conditions, and each rules out a different way of being wrong:
  ##
  ##   * no unknown opcode — a number outside the table means the recording used
  ##     an instruction set this table is not;
  ##   * every prediction held — one mismatch is a table that is describing some
  ##     other instruction set that happens to agree in places;
  ##   * at least one prediction was made — a recording of pure branches would
  ##     otherwise pass by never being asked anything.
  c.unknown == 0 and c.checked > 0 and c.matched == c.checked

func explainsProgramCounters*(pc, op, ctx: openArray[int]): OpcodeTableCheck =
  ## Does this table's instruction lengths reproduce the recording's own program
  ## counters?
  ##
  ## A prediction is made only where one is possible: consecutive steps in the
  ## same execution context whose first instruction does not branch. Everything
  ## else is counted as skipped rather than silently passed, so a caller can tell
  ## "checked nothing" from "checked and agreed".
  ##
  ## `ctx` may be shorter than `pc` (a recording that wrote no context column);
  ## a missing context is treated as the same context, which is the assumption
  ## the single-context recordings this site publishes actually satisfy.
  ##
  ## ## A STEP WITH NO COUNTER IS SKIPPED, AND THIS IS THE PLACE IT MATTERS MOST
  ##
  ## `instruction_listing.NoProgramCounter` marks a step whose coordinate is a
  ## source position rather than an offset — a partly-positioned recording has
  ## both kinds. It is `-1`, so a transition into or out of one would produce a
  ## difference that is negative or absurdly large, which is a MISMATCH; and
  ## `explains` requires `matched == checked`, so ONE such transition withdraws
  ## the opcode names from the entire recording. On
  ## `aztec-testnet-frames/0x0a807e4e…` there are four such boundaries and the
  ## table explains all 25 of its opcodes, so the names would have been lost to
  ## an artefact of the sentinel rather than to anything about the recording.
  ##
  ## Counted as `skipped` and not silently passed, for the reason the branch and
  ## context cases are: the difference between "checked nothing" and "checked and
  ## agreed" is the whole evidential value of this function.
  const NoPc = -1
  let n = min(pc.len, op.len)
  for i in 0 ..< n:
    if not knownAvmOpcode(op[i]): inc result.unknown
  if result.unknown > 0: return
  for i in 0 ..< n - 1:
    let sameContext =
      ctx.len <= i + 1 or ctx[i] == ctx[i + 1]
    if pc[i] == NoPc or pc[i + 1] == NoPc or
       AvmInstructionSet[op[i]].branches or not sameContext:
      inc result.skipped
      continue
    inc result.checked
    if pc[i + 1] - pc[i] == AvmInstructionSet[op[i]].size: inc result.matched
