## tests/test_chain_reach.nim — the chain landing page's §4-item-4 statement.
##
## Chain-Support-Matrix.md §4 item 4 makes a landing page "stating the debug
## tier, historical reach, and known limitations in plain language" a condition
## of listing a chain at all, and §5 step 8 repeats it. `components/reach.nim`
## is the statement; this file grades it.
##
## ## Why the sentence selection is graded exhaustively and not by sampling
##
## Every sentence under test is a claim about a real chain that a visitor acts
## on. "Debuggable back to block 67010" is a statement somebody will trust
## before spending an hour on a transaction below it, and the cost of getting it
## backwards is not a cosmetic one. So:
##
##   * every member of `ReachKind` is driven — `for k in ReachKind`, so a token
##     added to Chain-Support-Matrix.md §1.3's vocabulary fails this file rather
##     than rendering as nothing;
##   * both NON-declared states are driven, separately, because a row that said
##     nothing and a row that said something this build cannot read are
##     different facts and must not produce one sentence;
##   * the `stated == false` floor is driven against a `stated == true` floor of
##     height ZERO, which is the pair this whole module exists to keep apart: a
##     floor of zero is a chain reachable to genesis and "nobody said" is not
##     that.
##
## ## And why there are mutation arms
##
## A check that has never been seen to fail has not been shown to test
## anything. The two arms at the end deliberately hand the renderer a profile
## whose reach is declared and whose floor is absent, and a profile with a
## reason but no declared reach, and assert the page does NOT make the claim
## that the naive composition would have made. Both were real drafts of this
## module.
##
## NO MOCKS. `ChainProfile` is a plain value from the published contract and
## `parseChainProfile` is the real parser; the tests that go through a tree use
## the real registry JSON shape. There is nothing here a fake could stand in
## for.

import std/[unittest, json, strutils]

import blocktracer_client
import ../src/components/reach

proc rowWith(reach: JsonNode = nil, floor: JsonNode = nil,
             vm: JsonNode = nil): JsonNode =
  ## A registry row carrying only the members a case is about, built through the
  ## REAL parser rather than by constructing a `ChainProfile` by hand — so these
  ## arms also cover the parse, and a member renamed on the wire fails here.
  result = %*{"recorder": {"id": "x"}}
  if reach != nil: result["reach"] = reach
  if floor != nil: result["historyFloor"] = floor
  if vm != nil: result["vm"] = vm

suite "the chain landing page states historical reach":

  test "every member of §1.3's vocabulary produces a sentence":
    # The exhaustive walk. A token added to `ReachKind` with no limb in
    # `reachLead` would reach this and fail, which is the direction that
    # matters: a chain declaring a reach this page cannot describe must not
    # render an empty region.
    for k in ReachKind:
      let p = parseChainProfile(rowWith(reach = %($k)))
      check p.reach.state == dsDeclared
      let st = reachStatement(p)
      check st.lead.len > 60
      # Every declared reach explains WHY the question arises before answering
      # it. Without that clause the sentence is about an internal noun.
      check "needs the state the chain was in just before it ran" in st.lead

  test "a row that said nothing and a row this build cannot read differ":
    let absent = reachStatement(parseChainProfile(rowWith()))
    let unknown = reachStatement(
      parseChainProfile(rowWith(reach = %"eventually-consistent")))
    check "states no historical reach" in absent.lead
    check "does not recognise" in unknown.lead
    # The unrecognised sentence QUOTES the token, so an operator reading the
    # page can tell which producer wrote it.
    check "eventually-consistent" in unknown.lead
    check absent.lead != unknown.lead
    # Neither claims a boundary, and neither is silent.
    check "block " notin absent.lead
    check "block " notin unknown.lead

  test "a stated floor of zero is not the same as an unstated floor":
    let zero = reachStatement(parseChainProfile(rowWith(
      reach = %"floor",
      floor = %*{"height": 0, "reason": "probed to genesis"})))
    let unstated = reachStatement(parseChainProfile(rowWith(reach = %"floor")))
    check "down to block 0" in zero.lead
    check "registry row does not state the position of" in unstated.lead
    check zero.lead != unstated.lead
    # THE WEAKER CLAIM IS MADE DELIBERATELY. A measured floor at genesis is a
    # lower bound on the reach, and `archive` — the token for "any historical
    # block" — is what it is NOT. The page says so rather than rounding up.
    check "lower bound" in zero.lead
    check "archive" in zero.lead

  test "a windowed chain is told the boundary moves":
    let st = reachStatement(parseChainProfile(rowWith(
      reach = %"windowed",
      floor = %*{"height": 67010,
                 "reason": "prestate was obtainable from 67010 upward when " &
                           "this generation was captured, and not below it"})))
    check "block 67010 and above" in st.lead
    check "MOVES UP as the chain advances" in st.lead
    # THE ARM THAT `/aztec` FORCED. That chain publishes blocks 68,062 to
    # 68,231 and declares a floor at 70,157, so every transaction it publishes
    # is BELOW its own floor and every one of them has a working Debug button.
    # The first draft said "what it cannot do is step", which contradicted the
    # controls on the same page. The floor governs whether a NEW recording can
    # be made — `FloorVerdict.fvBelow` is "no generation can succeed" — and
    # this arm pins both halves of the correction.
    check "LIMIT ON WHAT CAN BE RECORDED" in st.lead
    check "steps from it for good" in st.lead
    check "cannot do is step" notin st.lead
    # The producer's note is carried VERBATIM and separately, because it has a
    # different author from every other sentence in the section.
    check st.note == "prestate was obtainable from 67010 upward when this " &
                     "generation was captured, and not below it"
    check st.note notin st.lead

  test "a self-contained chain is not described with a floor":
    let st = reachStatement(parseChainProfile(rowWith(reach = %"self-contained")))
    check "carries the state it reads with it" in st.lead
    check "no longer exists anywhere" notin st.lead
    check "LIMIT ON WHAT CAN BE RECORDED" notin st.lead

  test "the instruction set is stated when the row declares one, and not otherwise":
    let withIsa = reachStatement(parseChainProfile(rowWith(
      reach = %"floor", vm = %*{"instructionSet": "evm"})))
    check "written against the evm instruction set" in withIsa.isa
    # The honest half: where source does not resolve, THIS is the granularity,
    # and the per-transaction page is named as the place that says which.
    check "each transaction's page states which of the two it got" in withIsa.isa
    let noIsa = reachStatement(parseChainProfile(rowWith(reach = %"floor")))
    check noIsa.isa.len == 0

  test "a note is not quoted under a sentence that states no boundary":
    # MUTATION ARM 1, and it was a real draft. Composing `note` from
    # `floor.reason` unconditionally puts "how that boundary was established"
    # under a paragraph that has just said there is no stated boundary — a page
    # contradicting itself inside two paragraphs.
    let st = reachStatement(parseChainProfile(rowWith(
      floor = %*{"height": 12, "reason": "measured by bisection"})))
    check st.lead.contains("states no historical reach")
    check st.note.len == 0

  test "a declared floor with no height does not render a bare number":
    # MUTATION ARM 2. `floorPhrase` reading `f.height` without consulting
    # `f.stated` renders "block 0 and above" for a row that stated nothing,
    # which is the single most expensive wrong sentence this section could
    # carry: it promises full history for a chain that promised nothing.
    let st = reachStatement(parseChainProfile(rowWith(reach = %"windowed")))
    check "block 0 and above" notin st.lead
    check "does not state the position of" in st.lead

  test "the rendered section carries the heading and every sentence it has":
    let html = reachSection(parseChainProfile(rowWith(
      reach = %"floor",
      floor = %*{"height": 0, "reason": "probed to genesis"},
      vm = %*{"instructionSet": "evm"})))
    check ReachHeading in html
    check "down to block 0" in html
    check "probed to genesis" in html
    check "evm instruction set" in html
    # The quotation is MARKED as one.
    check "in the pipeline's own words" in html

  test "the section renders for a chain that declares nothing at all":
    # Rendered unconditionally, and this is the arm that pins it: a region that
    # vanished when a chain declared nothing would make the weakest chains the
    # ones that say least about themselves, which is backwards.
    let html = reachSection(parseChainProfile(nil))
    check ReachHeading in html
    check "states no historical reach" in html
