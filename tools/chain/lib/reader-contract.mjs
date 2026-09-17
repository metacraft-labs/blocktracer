// reader-contract.mjs — WHAT THE READER ACTUALLY CONSUMES, read out of the reader.
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────────────────
//
// The producer seam is a document (`Data-Contract.md` §5) and a reader
// (`src/blocktracer/chain/ingest.nim`). Until this file, the only way to know whether the
// two agreed was for a person to read both and agree with themselves — and the measured
// result of that was §5 naming NINE member paths against a reader that consumed 117 over
// 22 containers: 108 unnamed, 19 of them by unguarded bracket access, which in Nim's
// `std/json` RAISES `KeyError` on an absent key rather than answering null. (Those four are
// the measurement taken on 2026-09-17, when the gap was closed, and they are the size of
// the GAP rather than the size of the census — the census has grown since and its current
// figures are printed by `snapshot-contract-selftest.mjs` §1 and §2, which is where a
// current figure belongs.) One of the 19's siblings, `provenance.l1ChainId`, was omitted by
// the real follower's own mainnet output: the producer this repository ships wrote a
// snapshot the reader this repository ships crashed on, and every committed fixture
// carried the member so nothing could see it.
//
// WHAT "NINE" COUNTS, because §5 admits three readings and only one makes 108 follow. The
// nine are the member paths §5 stated as REQUIREMENTS on a conforming snapshot: §5.2's
// six-row required-members table (`format`, `provenance`, `window`, `counts`, `blocks`,
// `transactions`) plus the three its prose makes mandatory — `provenance.chain`, `reason`,
// `refusalReason`. Counting only §5.2's table gives six and makes the gap 111; counting
// every member §5 mentions at all gives twelve, adding `container` (mentioned as a
// permission), `counts.accountedFor` (mentioned as version history) and `outcome` (a legacy
// column header). The figures here, in the `Justfile`, in `ci.yml` and in
// `snapshot-contract-selftest.mjs` are all the nine-reading: 117 − 9 = 108, and of the 23
// members the reader takes by an unguarded bracket, 4 are among the nine and 19 are not.
//
// So the consumed set is EXTRACTED from the reader rather than transcribed beside it. A
// transcription is a second copy that drifts; an extraction goes stale the moment the
// reader changes, and the check that reads it goes red.
//
// ── WHAT IT EXTRACTS, AND WHY THAT IS DECIDABLE WITHOUT A NIM PARSER ──────────────────
//
// `std/json` gives a reader exactly two subscripts, and they are the whole vocabulary:
//
//   node["k"]   REQUIRED    — raises `KeyError` when `k` is absent
//   node{"k"}   OPTIONAL    — answers a nil `JsonNode` when `k` is absent
//
// The difference is the whole of what "required" means to a reader, so the access form is
// the evidence and no annotation is needed. What has to be decided is which NODE a given
// subscript is applied to, and that is a scope-and-binding question over a language whose
// blocks are indentation: this walks the file, maintains the binding stack, and resolves
// `let` / `var` / `for` right-hand sides to the container they denote.
//
// THE RULES THAT MAKE IT SOUND, each of which was a wrong answer first:
//
//   * A `.getStr` / `.getInt` / `.kind` / `.len` TERMINATES a chain. `let txHash =
//     t["txHash"].getStr` binds a string, not a node, and treating it as a node attributed
//     the positions sidecar's seven members to `transactions[].txHash`.
//   * A `%*{…}` / `newJObject()` right-hand side is CONSTRUCTED OUTPUT, never a view onto
//     the input. Without this rule `native["replay"] = …` attributed a member named
//     `replay` to THREE different input members at once: `var native = %*{…}` at
//     `ingest.nim:1234` is built from `t["revertCode"]`, `t{"bodyRetained"}` and
//     `t{"effectVisible"}`, so ablating the rule resolves `native` to those three
//     containers and notes a `replay` member on each. Three is what the ablation
//     measures; this comment said five until 2026-09-17, which was a count of nothing.
//   * A subscript by a VARIABLE is dynamic. If the variable holds a literal set (`for col
//     in ["pathId", "line", "column"]`) every member of the set is consumed; otherwise the
//     container is an open map and is recorded as `*`.
//   * An accessor proc — `proc f(key: string): JsonNode` whose body subscripts a known
//     root by its own parameter — makes `f("lit")` an access on that root. `provOrNull` is
//     the one in this reader, and four provenance members are reached only through it.
//   * A sidecar's container id comes from the PATH the reader opens it at, resolved
//     through `cfg.snapshotDir / …`, so the same walk also yields the path census §5.1 is
//     checked against.
//
// ── WHAT IT DOES NOT CLAIM ────────────────────────────────────────────────────────────
//
// It is not a type checker and it does not evaluate. A member reached only on a branch
// that cannot be taken would still be recorded as consumed, which is the safe direction:
// the check it feeds fails when the SPEC is short of the reader, and over-reporting the
// reader can only make the spec more complete. The other direction — the spec naming a
// member nothing consumes — is where over-reporting could hide something, and that is why
// the extraction is compared for EQUALITY rather than containment.
//
// ── THE NINE SHAPES IT DOES NOT MODEL, AND WHY THEY ARE FORBIDDEN RATHER THAN MODELLED ─
//
// The paragraph above is about DIRECTION and it is not the whole disclosure. There are
// nine concrete access shapes this walk gets WRONG rather than conservatively, and eight
// of them fail in the dangerous direction: a member the reader really consumes is MISSED,
// so the equality check compares two short lists and agrees. The ninth fails the other
// way and INVENTS a member out of text that is not code.
//
// None of the nine appears in the reader today — that was measured, shape by shape — so
// §5.2b is complete as of 2026-09-17. But "complete today" and "gated" are different
// claims, and a silent under-report is the worst failure a coverage check has, because it
// looks exactly like success. So the nine are BANNED rather than modelled:
// `readerShapeViolations` below refuses each of them, `snapshot-contract-selftest.mjs` §8
// runs it over `ingest.nim`, and each of the nine has a control that plants it and
// requires the lint to fire. Modelling them would be a Nim front end.
//
// A BAN IS ONLY AS WIDE AS ITS SPELLING, and this file learned that the expensive way. It
// said "one regex apiece" and meant it: shapes 1 and 8 were `/\.getOrDefault\(\s*"/` and
// `/\.to\(/`, both of which require dot syntax AND a parenthesis. A review planted a
// genuinely new member at a real row site and kept the whole suite green through three
// spellings that all compile — `t.getOrDefault "k"`, `getOrDefault(t, "k")` and
// `to(t, T)` — so shape 1's "banned in the string-literal form, which is the form that
// names a member" and shape 8's "banned outright" were both claims about a rule that did
// not exist. Each of those two shapes is now the SET of its four spellings (see
// `GET_OR_DEFAULT_BY_LITERAL` and `WHOLE_OBJECT_TO`), and §8 asserts both directions per
// spelling rather than per shape. What is still true of the OTHER seven is that each is one
// regex, and the honest statement of their reach is the regex itself and not this
// paragraph: shapes 2, 3, 5 and 6 key on a string-literal subscript inside a block whose
// declaration they match, so a member reached through an alias bound outside that block is
// not a spelling they cover. That is a known limit of those four rules and is stated here
// rather than implied away.
//
//   1. `node.getOrDefault("k")`. A member read that is neither of the two subscripts, so
//      the walk never sees it. Banned wherever the KEY is a string literal, which is the
//      form that names a member — in all four spellings Nim admits: `t.getOrDefault("k")`,
//      `t.getOrDefault "k"`, `getOrDefault(t, "k")` and `getOrDefault t, "k"`. The key is
//      argument 1 in the dot forms and argument 2 in the bare ones, and the rules say so,
//      because `ingest.nim` passes a string literal as the DEFAULT twice
//      (`byHeight.getOrDefault(height, "")`) and a position-blind rule would flag it. The
//      reader's eight `Table` lookups all key by an identifier, so the rule is satisfiable
//      as written rather than aspirational — measured at zero hits, all four spellings.
//   2. A TWO-VARIABLE `for k, v in x` / `x.pairs()`. Neither loop variable is bound by
//      the walk (it matches `for <one> in …`), so a subscript on either is invisible.
//      Banned in the form where that matters: a two-variable `for` whose body subscripts
//      a loop variable by a string literal. The bare form appears ONCE, at
//      `ingest.nim:1539` (`for p, c in fs`, over a source bundle's `files`), and is
//      correct there precisely because it names no member — `files` is an open map whose
//      keys are the driver's own build paths, so there is nothing to census.
//   3. A HELPER `proc f(n: JsonNode)` whose body subscripts its parameter. The walk models
//      exactly one proc shape — the accessor, `proc f(key: string): JsonNode` — and a
//      helper that takes the node instead consumes members under a name the walk has no
//      binding for. Banned in that form; `writeJson` and `orNull` take a `JsonNode` and
//      subscript nothing, so they are unaffected.
//   4. A SEQ/ARRAY ELEMENT, `rows[0]["k"]`. The walk's subscript regex reads a string key
//      or a bare identifier, so an integer index breaks the chain and the member after it
//      is lost. Banned as an integer-literal subscript followed by a member subscript.
//   5. A `template` body. Templates are expanded by the compiler and not by this walk, so
//      a subscript inside one is attributed to nothing. Banned as a template whose body
//      subscripts by a string literal; the reader declares no template at all.
//   6. An ANONYMOUS proc or closure. Its parameters are bound by the call, not by a `let`,
//      so the walk cannot know what they denote. Banned as an anonymous `proc (`/`=>`
//      whose body subscripts by a string literal; the reader's two anonymous procs are
//      `sort` comparators that subscript nothing.
//   7. A SUBSCRIPT SPLIT ACROSS LINES. The walk reads one physical line for accesses (only
//      a `let`/`var` right-hand side is joined), so `node[` with its key on the next line
//      is not seen at all. Banned as a line ending in an identifier immediately followed by
//      an opening `[` or `{`; the ten multi-line `%*{` constructors do not match, because
//      what precedes their brace is `%*`.
//   8. `snap.to(T)`. A whole-object unmarshal consumes every member of a type declared
//      elsewhere, which is unbounded from here. Banned outright, and "outright" means all
//      four spellings — `t.to(T)`, `t.to T`, `to(t, T)` and `to t, T` — not the dotted
//      parenthesised one the sentence used to mean. There is no admissible form of this
//      shape, so unlike shape 1 no argument position is involved: any `to` applied to a
//      receiver is a violation.
//   9. A TRIPLE-QUOTED STRING. This is the one that fails the other way: the walk strips
//      `#` comments and tracks single-line string state, so a `"""…"""` block containing
//      something shaped like `x["k"]` is read as CODE and INVENTS a member the reader does
//      not consume — which then shows up as a census gap in the spec-only direction and
//      gets "fixed" by adding a member to §5 that nothing reads. Banned outright.

/** `node["k"]` — absent key raises. */
export const REQUIRED = 'required';
/** `node{"k"}` — absent key answers nil. */
export const OPTIONAL = 'optional';

const TERMINATORS = /^\s*\.\s*(get[A-Za-z]*|kind|len|isNil|pretty|elems|fields)\b/;
const CONSTRUCTOR = /^\s*(%\*|%\s*[[{]|newJObject\b|newJArray\b|newJNull\b|newJString\b|newJInt\b|newJBool\b)/;

const indentOf = (s) => /^[ \t]*/.exec(s)[0].length;

/** `#` outside a string literal opens a comment. */
function stripComment(s) {
  let out = '', inStr = false;
  for (let k = 0; k < s.length; k++) {
    const c = s[k];
    if (c === '"' && s[k - 1] !== '\\') inStr = !inStr;
    if (c === '#' && !inStr) break;
    out += c;
  }
  return out;
}

/**
 * Walk a Nim reader and report every snapshot member it consumes and every
 * snapshot-relative path it opens.
 *
 * @param {string} text            the reader's source
 * @param {string} rootFile        the file read by name that seeds the walk ("snapshot.json")
 * @param {string} rootContainer   the container id that file's parse denotes ("snapshot")
 * @param {object} consts          named path defaults the reader spells as constants, so a
 *                                 default STATED IN THE CONTRACT and a default open-coded in
 *                                 the reader are distinguishable: a constant this map does
 *                                 not hold leaves the path unresolved and the walk says so.
 */
export function extractReaderContract(text, rootFile = 'snapshot.json', rootContainer = 'snapshot',
                                      consts = {}) {
  const lines = text.split('\n');

  /** container id -> Map(member -> {access, sites:number[]}) */
  const consumed = new Map();
  const note = (container, member, access, line) => {
    if (!consumed.has(container)) consumed.set(container, new Map());
    const m = consumed.get(container);
    const cur = m.get(member) ?? { access: OPTIONAL, sites: [] };
    if (access === REQUIRED) cur.access = REQUIRED;
    if (!cur.sites.includes(line)) cur.sites.push(line);
    m.set(member, cur);
  };

  /** every `cfg.snapshotDir / …` the reader resolves, classified */
  const paths = [];
  /** binding stack: {name, scopeIndent, containers:Set|null, literals:string[]|null} */
  let scope = [];
  const tableElem = new Map();      // table name -> Set<container>
  const pathVars = new Map();       // name -> {expr, line}
  const stringVars = new Map();     // name -> literal path fragments assigned to it
  const accessors = new Map();      // proc name -> {container, access}
  const diagnostics = [];
  /** files the reader parses that are NOT snapshot-relative — see §5.4's boundary */
  const outsideReads = [];

  const lookup = (name) => {
    for (let k = scope.length - 1; k >= 0; k--) if (scope[k].name === name) return scope[k];
    return null;
  };
  const popTo = (indent) => {
    while (scope.length && scope[scope.length - 1].scopeIndent > indent) scope.pop();
  };

  /** the set of containers an expression can denote */
  function resolve(expr) {
    const out = new Set();
    if (CONSTRUCTOR.test(expr)) return out;          // constructed output, not input
    const re = /\b([A-Za-z_][A-Za-z0-9_]*)((?:\s*[[{]\s*"[^"]*"\s*[\]}])*)/g;
    let m;
    while ((m = re.exec(expr)) !== null) {
      const rest = expr.slice(re.lastIndex);
      if (TERMINATORS.test(rest)) continue;          // the chain ends in a scalar
      const b = lookup(m[1]);
      let roots = b && b.containers ? b.containers : null;
      if (!roots && tableElem.has(m[1]) && /^\s*\[\s*[A-Za-z_]/.test(rest)) roots = tableElem.get(m[1]);
      if (!roots) continue;
      const steps = [...m[2].matchAll(/[[{]\s*"([^"]*)"\s*[\]}]/g)].map((x) => x[1]);
      for (const r of roots) out.add([r, ...steps].join('.'));
    }
    return out;
  }

  /**
   * A sidecar's container id is the literal directory (or file) it is opened at.
   * A path spelled by a VARIABLE resolves through that variable's own conventional
   * default, which is how `sources/` is reached: the row names the file and the
   * default is the fallback, so the container is still decidable.
   */
  function containerIdForPath(expr) {
    let text = expr;
    for (const [k, v] of Object.entries(consts)) text = text.split(k).join(JSON.stringify(v));
    const bare = /^([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(expr.trim());
    if (bare && stringVars.get(bare[1])?.fallback) text = stringVars.get(bare[1]).fallback;
    const literals = [...text.matchAll(/"([^"]*)"/g)].map((x) => x[1]).filter((s) => s && s !== '.json');
    if (literals.length === 0) return null;
    const head = literals[0];
    if (head === rootFile) return rootContainer;
    if (!/\.json$/.test(head) && !text.includes('.json')) return null;  // not a JSON sidecar
    return 'sidecar:' + head.replace(/\.json$/, '');
  }

  let skipUntil = -1;   // an accessor proc's own body: its subscripts are the accessor, not a use

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const lineNo = i + 1;
    if (raw.trim() === '' || /^\s*#/.test(raw)) continue;
    const ind = indentOf(raw);
    if (skipUntil >= 0 && ind > skipUntil) continue;
    if (skipUntil >= 0 && ind <= skipUntil) skipUntil = -1;
    popTo(ind);
    const single = stripComment(raw);

    // ── the logical line: a binding whose right-hand side continues onto more-indented
    // lines is ONE expression. An `if/elif/else` spread over five lines resolves to the
    // union of its arms only when it is read whole.
    let logical = single;
    if (/^\s*(let|var)\s/.test(single)) {
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].trim() === '' || /^\s*#/.test(lines[j])) continue;
        if (indentOf(lines[j]) > ind) logical += ' ' + stripComment(lines[j]).trim(); else break;
      }
    }

    // ── 1. member accesses on bound names, BEFORE this line's own binding shadows ──
    {
      const re = /\b([A-Za-z_][A-Za-z0-9_]*)((?:\s*[[{]\s*(?:"[^"]*"|[A-Za-z_][A-Za-z0-9_]*)\s*[\]}])+)/g;
      let m;
      while ((m = re.exec(single)) !== null) {
        const b = lookup(m[1]);
        if (!b || !b.containers) continue;
        const steps = [...m[2].matchAll(/([[{])\s*(?:"([^"]*)"|([A-Za-z_][A-Za-z0-9_]*))\s*[\]}]/g)];
        for (const root of b.containers) {
          let cur = root;
          for (const s of steps) {
            const access = s[1] === '[' ? REQUIRED : OPTIONAL;
            if (s[2] !== undefined) { note(cur, s[2], access, lineNo); cur += '.' + s[2]; continue; }
            const vb = lookup(s[3]);
            if (vb && vb.literals) { for (const lit of vb.literals) note(cur, lit, access, lineNo); }
            else note(cur, '*', access, lineNo);
            cur = null;
            break;
          }
        }
      }
    }

    // ── 2. accessor-proc call sites ───────────────────────────────────────────────
    for (const [pname, info] of accessors) {
      const re = new RegExp('\\b' + pname + '\\(\\s*"([^"]*)"\\s*\\)', 'g');
      let m;
      while ((m = re.exec(single)) !== null) note(info.container, m[1], info.access, lineNo);
    }

    // ── 3. snapshot-relative path reads ───────────────────────────────────────────
    {
      const m = /cfg\.snapshotDir\s*\/(.+)$/.exec(single);
      if (m) {
        const expr = m[1].trim();
        // how is this path NAMED? by a literal, by a row member, or by a variable that
        // resolves to one of the two.
        let named = 'convention';
        let member = null;
        const rowRef = /\b([A-Za-z_][A-Za-z0-9_]*)\s*[[{]\s*"([^"]*)"\s*[\]}]/.exec(expr);
        if (rowRef && lookup(rowRef[1])?.containers) {
          named = 'row-member';
          member = [...lookup(rowRef[1]).containers][0] + '.' + rowRef[2];
        } else {
          const bare = /^([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(expr);
          if (bare && stringVars.has(bare[1])) {
            const hint = stringVars.get(bare[1]);
            named = hint.named;
            member = hint.member;
          } else if (/^"[^"]*"\s*$/.test(expr)) named = 'by-name';
        }
        paths.push({ expr, line: lineNo, named, member, container: containerIdForPath(expr) });
      }
    }

    let m;
    // ── 4. accessor proc declaration ──────────────────────────────────────────────
    if ((m = /^\s*proc\s+([A-Za-z_][A-Za-z0-9_]*)\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*string\s*\)\s*:\s*JsonNode/.exec(single)) !== null) {
      const [, pname, param] = m;
      for (let j = i + 1; j < lines.length && (lines[j].trim() === '' || indentOf(lines[j]) > ind); j++) {
        const mm = new RegExp('\\b([A-Za-z_][A-Za-z0-9_]*)\\s*([[{])\\s*' + param + '\\s*[\\]}]').exec(stripComment(lines[j]));
        if (!mm) continue;
        const b = lookup(mm[1]);
        if (b && b.containers) {
          for (const c of b.containers) accessors.set(pname, { container: c, access: mm[2] === '[' ? REQUIRED : OPTIONAL });
        } else diagnostics.push(`${lineNo}: accessor ${pname} subscripts an unbound '${mm[1]}'`);
        break;
      }
      skipUntil = ind;
      continue;
    }

    // ── 5. bindings ───────────────────────────────────────────────────────────────
    if ((m = /^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+?):?\s*$/.exec(logical)) !== null) {
      const [, name, rhs] = m;
      const litArr = /^\[\s*"[^"]*"(?:\s*,\s*"[^"]*")*\s*\]$/.exec(rhs.trim());
      if (litArr) {
        scope.push({ name, scopeIndent: ind + 1, containers: null, literals: [...rhs.matchAll(/"([^"]*)"/g)].map((x) => x[1]) });
      } else {
        const cs = resolve(rhs);
        scope.push({ name, scopeIndent: ind + 1, containers: cs.size ? new Set([...cs].map((c) => c + '[]')) : null, literals: null });
      }
      continue;
    }
    if ((m = /^\s*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*?)?=\s*(.+)$/.exec(logical)) !== null) {
      const name = m[1]; const rhs = m[2].trim();
      const pm = /^cfg\.snapshotDir\s*\/(.+)$/.exec(rhs);
      if (pm) { pathVars.set(name, pm[1].trim()); scope.push({ name, scopeIndent: ind, containers: null, literals: null }); continue; }
      const pj = /parseJson\(\s*readFile\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)\s*\)/.exec(rhs);
      if (pj) {
        // A `parseJson(readFile(P))` whose `P` is NOT a snapshot-relative path is a read of
        // the OUTPUT tree or of a tool's own state and is none of this contract's business.
        // It is recorded rather than passed over: "this reader opens files the snapshot
        // contract does not cover" is a fact §5.4's producer-internal boundary is about,
        // and a walk that dropped it silently could not say so.
        const pv = pathVars.get(pj[1]);
        const cid = pv ? containerIdForPath(pv) : null;
        if (pv && !cid) diagnostics.push(`${lineNo}: parseJson of an unresolved snapshot path '${pj[1]}'`);
        if (!pv) outsideReads.push({ line: lineNo, via: pj[1] });
        scope.push({ name, scopeIndent: ind, containers: cid ? new Set([cid]) : null, literals: null });
        continue;
      }
      // a STRING holding a snapshot-relative path, so `cfg.snapshotDir / srcRel` can be
      // classified by how `srcRel` itself was named.
      const rowRef = /^([A-Za-z_][A-Za-z0-9_]*)\s*[[{]\s*"([^"]*)"\s*[\]}]\s*\.getStr/.exec(rhs);
      if (rowRef && lookup(rowRef[1])?.containers) {
        stringVars.set(name, { named: 'row-member', member: [...lookup(rowRef[1]).containers][0] + '.' + rowRef[2] });
      }
      const cs = resolve(rhs);
      scope.push({ name, scopeIndent: ind, containers: cs.size ? cs : null, literals: null });
      continue;
    }
    // plain assignment: union into the existing binding (a `var` filled on two branches).
    // A ONE-LINE `if cond: x = …` counts, because that is how a conventional default is
    // spelled beside a row-named path and dropping it loses the whole `sources/` sidecar.
    m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/.exec(single)
      ?? /^\s*(?:if|elif|else)\b[^:]*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/.exec(single);
    if (m !== null &&
        !/^\s*(let|var|const|proc|func|template|while|for|return|result|case|of|import)\b/.test(single)) {
      const name = m[1]; const rhs = m[2].trim();
      const b = lookup(name);
      const pj = /parseJson\(\s*readFile\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)\s*\)/.exec(rhs);
      if (b && pj) {
        const cid = pathVars.has(pj[1]) ? containerIdForPath(pathVars.get(pj[1])) : null;
        if (cid) b.containers = new Set([...(b.containers ?? []), cid]);
      } else if (b) {
        const cs = resolve(rhs);
        if (cs.size) b.containers = new Set([...(b.containers ?? []), ...cs]);
      }
      // `if srcRel.len == 0: srcRel = DefaultSourcesDir / (txHash & ".json")` — the
      // contract's own default beside the row member. Recorded so the path census can
      // say the row NAMES it and the DEFAULT is the fallback, which are two different
      // claims about one path. The constant is substituted first: a default the
      // contract states and a default the reader open-codes must not read alike, and
      // a constant `consts` does not hold stays unresolved and is reported.
      let literal = rhs;
      for (const [k, v] of Object.entries(consts)) literal = literal.split(k).join(JSON.stringify(v));
      if (/^"/.test(literal)) {
        stringVars.set(name, { named: 'row-member-or-default',
                               member: stringVars.get(name)?.member ?? null,
                               fallback: literal });
      }
    }
    // table element assignment `T[k] = v`
    if ((m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*[A-Za-z_][A-Za-z0-9_]*\s*\]\s*=\s*(.+)$/.exec(single)) !== null) {
      const cs = resolve(m[2].trim());
      if (cs.size) tableElem.set(m[1], new Set([...(tableElem.get(m[1]) ?? []), ...cs]));
    }
  }

  return { consumed, paths, diagnostics, outsideReads };
}

// ── THE BANS ───────────────────────────────────────────────────────────────────────────
//
// The nine shapes the header enumerates, as nine rules over the reader's text. Each is
// keyed by the SHAPE and not by a line, so nothing here can be satisfied by an exemption.

/** a string-literal subscript, which is what makes a shape name a member */
const KEYED = /[[{]\s*"[^"]*"\s*[\]}]/;

// WHY SHAPES 1 AND 8 ARE FOUR REGEXES EACH AND NOT ONE. Nim spells the same call four
// ways, and a rule written for one of them is a rule about punctuation rather than about
// the shape. `.getOrDefault(` and `.to(` were ALL this file banned until 2026-09-17, and a
// review planted a genuinely new member at a real row site and got the whole suite to stay
// green (rc 0, 117 vs 117) through three forms that all compile and all work:
//
//     t.getOrDefault "k"          # dot, COMMAND syntax — no parenthesis
//     getOrDefault(t, "k")        # CALL syntax — no dot, receiver is argument 1
//     to(t, T)                    # CALL syntax
//
// So each shape is the set of its spellings. WHERE THE KEY SITS MOVES WITH THE SPELLING,
// and that is load-bearing rather than pedantic: in the dot forms the string literal is
// argument ONE, in the bare forms it is argument TWO, and `ingest.nim` really does pass a
// string literal as `getOrDefault`'s DEFAULT — `byHeight.getOrDefault(height, "")` at two
// sites. A rule reading "a string literal anywhere in a `getOrDefault` call" would flag
// both, which is why the argument POSITION is part of every one of these four.
//
// AND THE RULE DISCRIMINATES ON THE RECEIVER RATHER THAN ON A LINE NUMBER. `getOrDefault`
// is legitimately present eight times, on Nim `Table`s (`isPositioned`, `isTraceless`,
// `byHeight`, `refusalReasonCounts`, `t` as a count table) — every one of them keyed by an
// IDENTIFIER, never by a literal, because a `Table` lookup in this reader is by a value it
// computed. That is what makes "the key is a string literal" the receiver test: a
// `JsonNode` member read names its member, a `Table` lookup in this reader does not. All
// eight regexes below were measured at ZERO hits over the unmodified `ingest.nim`, so the
// widening cost the green arm nothing and no shape carries an exemption.
//
// SIX OF THE EIGHT SPELLINGS COMPILE, and that too was measured rather than assumed, on Nim
// 2.2.10 on 2026-09-17, one file per spelling: both dot-paren, both dot-command and both
// call-paren do; the two CALL-COMMAND forms (`getOrDefault t, "k"`, `to t, T`) do not —
// Nim rejects command syntax in an expression position with `invalid indentation`. They are
// banned anyway, because the rule costs nothing and the parser's rules are not this file's
// invariant, but the reachable evasion set is six and the claim here says six.

/**
 * `getOrDefault` in every spelling in which its KEY is a string literal — the form that
 * names a member. Dot forms take the key as argument 1; bare forms as argument 2.
 */
const GET_OR_DEFAULT_BY_LITERAL = [
  /\.getOrDefault\s*\(\s*"/,                                  // t.getOrDefault("k")
  /\.getOrDefault\s+"/,                                       // t.getOrDefault "k"
  /(?<![A-Za-z0-9_.])getOrDefault\s*\(\s*[^,]*,\s*"/,         // getOrDefault(t, "k")
  /(?<![A-Za-z0-9_.])getOrDefault\s+[^,]*,\s*"/,              // getOrDefault t, "k"
];

/** `to` in every spelling. Banned outright — there is no admissible whole-object unmarshal. */
const WHOLE_OBJECT_TO = [
  /\.to\s*\(/,                                                // t.to(T)
  /\.to\s+[A-Za-z_]/,                                         // t.to T
  /(?<![A-Za-z0-9_.])to\s*\(/,                                // to(t, T)
  /(?<![A-Za-z0-9_.])to\s+[A-Za-z_][A-Za-z0-9_.[\]]*\s*,/,    // to t, T
];

/** the spellings each widened shape bans, named, so a suite can assert the set rather than the count */
export const SHAPE_SPELLINGS = {
  'getOrDefault-by-literal': ['dot-paren', 'dot-command', 'call-paren', 'call-command'],
  'whole-object-to': ['dot-paren', 'dot-command', 'call-paren', 'call-command'],
};

/** the body of an indentation block opened at `openIndent`, as lines */
function bodyOf(lines, from, openIndent) {
  const out = [];
  for (let j = from; j < lines.length; j++) {
    if (lines[j].trim() === '') continue;
    if (indentOf(lines[j]) <= openIndent) break;
    out.push(stripComment(lines[j]));
  }
  return out;
}

/**
 * Every occurrence, in `text`, of an access shape `extractReaderContract` does not model.
 *
 * @returns {{shape:string, line:number, text:string}[]} one entry per occurrence
 */
export function readerShapeViolations(text) {
  const lines = text.split('\n');
  const out = [];
  const hit = (shape, i, s) => out.push({ shape, line: i + 1, text: s.trim().slice(0, 100) });

  // 9 is checked over the RAW text, because it is the shape that defeats line-wise
  // comment and string handling in the first place.
  {
    const idx = text.indexOf('"""');
    if (idx >= 0) hit('triple-quoted-string', text.slice(0, idx).split('\n').length - 1, '"""');
  }

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    if (/^\s*#/.test(raw)) continue;
    const s = stripComment(raw);
    const ind = indentOf(raw);

    if (GET_OR_DEFAULT_BY_LITERAL.some((re) => re.test(s))) hit('getOrDefault-by-literal', i, s);
    if (WHOLE_OBJECT_TO.some((re) => re.test(s))) hit('whole-object-to', i, s);
    if (/\[\s*[0-9]+\s*\]\s*[[{]\s*"/.test(s)) hit('element-then-member', i, s);
    if (/[A-Za-z0-9_)\]]\s*[[{]\s*$/.test(s) && !/%\s*\*?\s*[[{]\s*$/.test(s)) {
      hit('subscript-split-across-lines', i, s);
    }

    // The block-bodied shapes: the declaration is the site, the body is the evidence.
    let m;
    if ((m = /^\s*for\s+[A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s+in\s/.exec(s)) !== null) {
      const names = [...s.matchAll(/^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s/g)][0];
      const body = [s.replace(/^[^:]*:\s*/, ''), ...bodyOf(lines, i + 1, ind)];
      const subscripted = body.some((b) =>
        new RegExp(`\\b(${names[1]}|${names[2]})\\s*[[{]\\s*"`).test(b));
      if (subscripted) hit('two-variable-for', i, s);
    }
    if ((m = /^\s*proc\s+[A-Za-z_][A-Za-z0-9_]*\s*\(([^)]*)\)/.exec(s)) !== null &&
        /:\s*JsonNode/.test(m[1]) && !/:\s*string\s*\)\s*:\s*JsonNode/.test(s)) {
      const params = [...m[1].matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*:\s*JsonNode/g)].map((x) => x[1]);
      const body = bodyOf(lines, i + 1, ind);
      if (body.some((b) => params.some((p) => new RegExp(`\\b${p}\\s*[[{]\\s*"`).test(b)))) {
        hit('json-node-parameter-helper', i, s);
      }
    }
    if (/^\s*template\s/.test(s)) {
      const body = [s, ...bodyOf(lines, i + 1, ind)];
      if (body.some((b) => KEYED.test(b))) hit('template-body', i, s);
    }
    if (/\bproc\s*\(/.test(s) || /=>/.test(s)) {
      const body = [s, ...bodyOf(lines, i + 1, ind)];
      if (body.some((b) => KEYED.test(b))) hit('anonymous-proc', i, s);
    }
  }
  return out;
}

// ── THE NIL-ACCESS BAN ─────────────────────────────────────────────────────────────────
//
// ONE FAMILY, SEVEN INSTANCES, THREE MILESTONES, AND NOTHING THAT COULD SEE IT COMING.
// Every one has the same shape: *a member the contract marks OPTIONAL, reached by the one
// access form that cannot survive its absence.*
//
//   * `provenance.l1ChainId` — `prov["l1ChainId"]`, a `KeyError`;
//   * `execSelectors[tracedAt]` with `tracedAt` = -1 — an `IndexDefect`, which is not even
//     a `CatchableError` and so escapes every refusal path there is;
//   * the position stream's `positioned` and `paths` — a nil `JsonNode` stored into a `%*`
//     literal and dereferenced by `toPretty`: a SEGFAULT;
//   * `artifact-resolution.transactions` — `for e in side{"transactions"}`, `items` on a
//     nil node: a SEGFAULT;
//   * the producer-side validator's `maps.height` and eight siblings — the same shape
//     again, in the binary a recorder team runs: a SEGFAULT, with no finding printed.
//
// Each was found by pointing a fixture at the code. None was found by reading it, and none
// of them could be: the committed captures all carried the member, so every arm in the
// repository ran over trees on which the defect is unreachable. That is what a source-shape
// ban is for — it is a statement about the CODE, not about the corpus, so it does not need
// an input that reaches the line.
//
// WHAT THE THREE SHAPES ARE. `node{"k"}` answers a NIL `JsonNode` for an absent key —
// that is the whole point of it, and it is why the census reads a `{}` as "optional". Nim's
// `std/json` then splits into accessors that tolerate that nil (`getStr`, `getInt`,
// `getElems`, `getFields`, `getBool`, and `{}` itself) and operations that dereference it
// without checking (`len`, `kind`, `items`/`pairs`, `[]`, and `%*` storage followed by
// `pretty`). The first set is the contract's own reading of an optional member. The second
// set applied DIRECTLY to a `{}` result is the family above, every time.
//
// WHAT IT PROVABLY DOES NOT COVER, measured rather than described, because "banned
// outright" about a regex that is not is a mistake this library has already made once:
//
//   * THE `KeyError` HALF. `node["k"]` on an optional member is the same family and this
//     ban cannot see it: `[]` is also the correct form for a REQUIRED member, so a token
//     ban on it is unsatisfiable. That half is covered for the reader — and only for the
//     reader — by the census equality check in §2, where the access form IS the statement
//     and both sides are compared. Everywhere else in `src/` it is uncovered.
//   * THE `IndexDefect` HALF. An integer index onto a producer-supplied sequence
//     (`xs[i]`, `xs[^1]`) is not a `{}` shape at all and is not scanned here.
//   * A `{}` RESULT BOUND TO A NAME FIRST. `let x = n{"k"}` then `for e in x:` or
//     `%*{"a": x}` evades every rule below, because the rules are written over the
//     subscript's own syntax. This is the widest hole and it is left open deliberately:
//     closing it needs local dataflow, and a rule that guessed would fire on the GUARDED
//     form — `let answered = side{"transactions"}` followed by a nil test — which is the
//     repair this ban exists to encourage. Asserted MISSED in the suite's attack table
//     rather than left unmentioned.
//   * ANYTHING OUTSIDE `src/`. The scope is data (`nilAccess.scopeRoot` in the census) and
//     the suite derives the file set from the tree, so it cannot shrink unnoticed; but
//     `client/`, `tools/` and the tests are not in it today.
//
// THE ONE ADMISSIBLE FORM IS A NIL TEST ON THE SAME EXPRESSION, and it is a RULE rather
// than an exemption list: a dereference is allowed when the identical subscript expression
// is compared to nil, or passed to `isNil`, earlier in the same boolean chain — which is
// how Nim's short-circuiting `or` makes `if x{"k"} == nil or x{"k"}.kind != JArray:` safe.
// No file, line or symbol is exempt.

/** the `std/json` operations that DEREFERENCE the node rather than checking it for nil */
const NIL_UNSAFE_ACCESSORS =
  'len|kind|items|pairs|mitems|mpairs|elems|fields|str|num|fnum|bval|add|delete|hasKey';

/** a dotted name followed by one or more `{"literal"}` subscripts — the optional-member read */
const OPTIONAL_READ = '[A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*(?:\\s*\\{\\s*"[^"]*"\\s*\\})+';

/** the shapes this ban refuses, named, so a suite can assert the set rather than a count */
export const NIL_ACCESS_SHAPES = Object.freeze([
  'nil-iteration', 'nil-json-value', 'nil-dereference',
]);

/** is `expr` nil-tested anywhere in `window` (the text that runs before the access)? */
function nilTested(window, expr) {
  const lit = expr.replace(/\s+/g, '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const flat = window.replace(/\s+/g, '');
  return new RegExp(`${lit}(?:==|!=)nil`).test(flat)
      || new RegExp(`isNil\\(${lit}\\)`).test(flat)
      || new RegExp(`${lit}\\.isNil`).test(flat);
}

/**
 * Every occurrence in `text` of the nil-access family: an optional-member read (`{}`)
 * reached by a form that dereferences the nil it answers.
 *
 * @returns {{shape:string, line:number, expr:string, text:string}[]} one entry per occurrence
 */
export function nilAccessViolations(text) {
  const lines = text.split('\n');
  const out = [];
  const hit = (shape, i, expr, s) =>
    out.push({ shape, line: i + 1, expr, text: s.trim().slice(0, 100) });

  // the two preceding non-blank code lines plus the part of this line to the left of the
  // access — a guard has to RUN before the dereference to be a guard
  const guardWindow = (i, upto) => {
    const before = [];
    for (let j = i - 1; j >= 0 && before.length < 2; j--) {
      if (lines[j].trim() === '') continue;
      before.unshift(stripComment(lines[j]));
    }
    return `${before.join('\n')}\n${upto}`;
  };

  for (let i = 0; i < lines.length; i++) {
    if (/^\s*#/.test(lines[i])) continue;
    const s = stripComment(lines[i]);

    // 1. ITERATION. `for x in n{"k"}:` — `items` on the nil node is a dead process, and
    //    `n{"k"}.getElems` answers the empty sequence, which is also the right READING:
    //    an absent array and an empty one say the same thing to a consumer.
    const it = new RegExp(`\\bfor\\s+[^:]*?\\bin\\s+(${OPTIONAL_READ})\\s*:`).exec(s);
    if (it) hit('nil-iteration', i, it[1].replace(/\s+/g, ''), s);

    // 2. JSON-VALUE POSITION. `"k": n{"m"},` inside a `%*` literal. `%*` stores the nil
    //    happily and `pretty` dereferences it later, from a stack that names `json.nim`
    //    and never mentions the snapshot that was short a key. `orNull(…)` is the form.
    const jv = new RegExp(`"[^"]*"\\s*:\\s*(${OPTIONAL_READ})\\s*[,)}\\]]*\\s*$`).exec(s);
    if (jv) hit('nil-json-value', i, jv[1].replace(/\s+/g, ''), s);

    // 3. DIRECT DEREFERENCE. `n{"k"}.len`, `n{"k"}.kind`, `n{"k"}[…]` — admissible only
    //    when the same expression was nil-tested first.
    const re = new RegExp(`(${OPTIONAL_READ})\\s*(?:\\.(?:${NIL_UNSAFE_ACCESSORS})\\b|\\[)`, 'g');
    let m;
    while ((m = re.exec(s)) !== null) {
      const expr = m[1].replace(/\s+/g, '');
      if (nilTested(guardWindow(i, s.slice(0, m.index)), expr)) continue;
      hit('nil-dereference', i, expr, s);
    }
  }
  return out;
}

/**
 * Every place `text` spells one of §5.1's path DEFAULTS as a literal in a PATH position —
 * an operand of the `/` join — rather than taking it from the census.
 *
 * WHY THE RULE IS "IN A PATH POSITION" AND NOT "ANYWHERE". Three of the five defaults are
 * also the names of the row members that override them (`t{"instructions"}`,
 * `t{"positions"}`), and `"sources"` is a key the reader WRITES into a published bundle.
 * Banning the bare token would ban the census's own member names, which is a rule no
 * reader could satisfy; banning it as an operand of the path join is exactly the defect —
 * `srcRel = "sources" / (txHash & ".json")` — and nothing else.
 *
 * @param {string[]} defaults  the default paths, from the census
 */
export function pathDefaultLiterals(text, defaults) {
  const out = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*#/.test(lines[i])) continue;
    const s = stripComment(lines[i]);
    for (const d of defaults) {
      const lit = JSON.stringify(d);
      const re = new RegExp(`(${lit}\\s*/)|(/\\s*${lit})`);
      if (re.test(s)) out.push({ default: d, line: i + 1, text: s.trim().slice(0, 100) });
    }
  }
  return out;
}

// ── THE CHAIN VOCABULARY BAN ───────────────────────────────────────────────────────────
//
// §5.3's six constants are read out of the snapshot now. The property that keeps them out
// is not "those six literals are gone" — it is that NO SEVENTH arrives, and a seventh
// arrives as a literal naming a chain, a VM, a fee token or an ecosystem language. One had
// already arrived where nobody was looking: `"schema": "avm-source-positions/1"`, a VM name
// in a published wire token, which no reading of the six would have found.
//
// THE VOCABULARY IS DATA (`snapshot-contract.json`'s `chainVocabulary`) and not a regex in
// here, for the reason the rule ids and the path defaults are: a check may only cite what
// the contract states, and a term list buried in a script is a rule nobody can look up.
// The terms' `kind` is which of §5.3's four categories each belongs to.
//
// ── WHAT THIS MATCHES, AND WHY EACH PART IS THERE ─────────────────────────────────────
//
// Each part was an evasion attempted against the scan before it was believed:
//
//   * CASE. `/…/i`, because `"Aztec"` names the chain exactly as `"aztec"` does.
//   * AN IDENTIFIER RATHER THAN A STRING. The match is over CODE, not over quoted text, so
//     `const aztecFee = …` is a violation. A ban that only looked inside quotes would be
//     satisfied by moving the name one token left.
//   * CONCATENATION. `"azt" & "ec"` compiles, produces `"aztec"`, and defeats any
//     per-token scan. String literals joined by `&` are SPLICED before matching — across
//     newlines too, since Nim allows the operands on separate lines — and the finding
//     reports the line the splice began on. `spliced: true` says which findings only a
//     spliced body could see.
//
//     THE QUOTES NEED NOT TOUCH THE `&`, and requiring that they did was a hole inside
//     this bullet's own claim: `("azt") & ("ec")` compiles, prints `aztec` and said
//     nothing. Parentheses are admitted on either side of the operator now.
//
//     NOR NEED BOTH OPERANDS BE QUOTED. `"azt" & suffixEc` is the same evasion with one
//     operand named, so every binding of a name to exactly one string literal is
//     collected and a `&`-ADJACENT occurrence of such a name is resolved to its literal
//     before the splice runs. The adjacency is the whole restriction: substituting
//     elsewhere would be constant folding, and a binding whose literal names a chain is
//     already a violation at its own declaration.
//   * BOUNDARIES THAT INCLUDE A CAMEL HUMP, which is not `\b` and is not a plain
//     non-alphanumeric run. `\b` is wrong because `-` and `/` are not word characters and
//     the tokens that matter are hyphenated and slashed: `aztec-avm` and
//     `avm-source-positions/1` must both match. A plain non-alphanumeric boundary is wrong
//     too, and that was measured rather than reasoned: with it, `let aztecFee = 1` named
//     the chain and the scan said nothing, which is the identifier evasion one token wide.
//     So a match is admitted when it starts at a non-alphanumeric boundary OR at an
//     uppercase letter following a lowercase one or a digit — `aztecFee`, `hasGas`,
//     `feeInGas` — and is rejected when a LOWERCASE letter follows it, which is what keeps
//     `manage` off `mana`, `gasoline` off `gas`, `suite` off `sui` and `refuel` off `fuel`.
//     The residual of that pair is an ALL-CAPS word whose interior spells a term
//     (`MANAGER` contains `MANA` followed by an uppercase letter): measured at zero over
//     every file in the ban's scope, and it is why the green arm is run over the real files
//     rather than asserted.
//
// ── AND WHAT IT CANNOT SEE ────────────────────────────────────────────────────────────
//
//   * A PROSE COMMENT, deliberately: comments are stripped first. The reader's comments
//     record which chain a decision was measured on, and a comment cannot reach a
//     published object. They are COUNTED and returned so a caller can report the figure
//     rather than write one down.
//   * A NAME SYNTHESISED rather than spelled — `chr(97) & …`, an escape (`"azt\x65c"`), a
//     `strformat` assembly, a homoglyph. No text scan reaches those. Stated as a residual
//     in the contract and in the suite that runs this, because "banned outright" about a
//     regex that is not is the failure this library has already made once.
//   * A TERM FOLLOWED BY A LOWERCASE LETTER — `"aztecnet"`, `"myaztecchain"`, `"gasoline"`.
//     This is not an oversight, it is the OTHER HALF of the boundary rule three bullets
//     up: the same clause that keeps `manage` off `mana` and `suite` off `sui` is the one
//     that lets `aztecnet` through, and there is no version of the rule that has one
//     without the other. Recorded here because a limit that is only implied by a regex is
//     a limit nobody knows about.
//   * A NAME ACCUMULATED RATHER THAN JOINED — `var s = "azt"` then `s.add "ec"`. The
//     splice reads `&` because `&` is where the operands sit in one expression; an
//     accumulation spreads them over statements and a text scan would have to interpret
//     the program to follow it. Same class as the synthesised names above.

// THE JOIN THE SPLICE RECOGNISES. The quotes need not be ADJACENT to the `&`: `("azt") &
// ("ec")` compiles, prints `aztec`, and the first spelling of this rule — which required
// them adjacent — said nothing about it. Parentheses are admitted on the closing side
// before the operator and on the opening side after it, which covers any depth of them.
//
// It is deliberately NOT a general expression parser. `foo("a") & ("b")` would be spliced
// to `"ab"` even though it concatenates a CALL's result with a literal, which is a false
// positive in the direction a ban may err — more findings, never fewer — and it is
// measured at zero over every file in the ban's scope by the green arm.
const SPLICE_JOIN = /"[ \t\r\n)]*&[ \t\r\n(]*"/g;

/** Drop every `" … & … "` join in `body`, carrying `bmap`'s offsets through. */
function spliceJoins(body, bmap) {
  const re = new RegExp(SPLICE_JOIN.source, 'g');
  let out = '';
  const map = [];
  let last = 0, m;
  while ((m = re.exec(body)) !== null) {
    for (let k = last; k < m.index; k++) { out += body[k]; map.push(bmap[k]); }
    last = m.index + m[0].length;
  }
  for (let k = last; k < body.length; k++) { out += body[k]; map.push(bmap[k]); }
  return { body: out, map };
}

/**
 * Substitute a `&`-adjacent identifier that a single-literal binding defines by its value.
 *
 * `"azt" & suffixEc` is the SAME evasion as `"azt" & "ec"` with one operand named, and a
 * splice that only joined quoted operands walked past it. So every `let`/`const`/`var`
 * bound to exactly one string literal is collected, and an occurrence of such a name
 * touching a `&` is rewritten to the literal it stands for — after which the ordinary
 * splice above joins it.
 *
 * `&`-ADJACENCY IS THE WHOLE RESTRICTION, and it is what keeps this from being a constant
 * folder. A name is substituted only where it is an operand of a concatenation, which is
 * the only place a substitution can manufacture a token that is not already spelled. A
 * binding whose literal itself names a chain is a violation at its own declaration line
 * and needs none of this.
 */
function resolveConcatOperands(body, bmap) {
  const consts = new Map();
  const decl = /(?:^|\n)[ \t]*(?:let|const|var)[ \t]+([A-Za-z_]\w*)\*?[ \t]*(?::[^=\n]*)?=[ \t]*"([^"\n]*)"/g;
  let d;
  while ((d = decl.exec(body)) !== null) consts.set(d[1], d[2]);
  if (consts.size === 0) return { body, map: bmap };
  let out = '';
  const map = [];
  const ident = /[A-Za-z_]\w*/g;
  let last = 0, m;
  while ((m = ident.exec(body)) !== null) {
    const value = consts.get(m[0]);
    if (value === undefined) continue;
    const joins = /&[ \t\r\n(]*$/.test(body.slice(Math.max(0, m.index - 40), m.index))
                  || /^[ \t\r\n)]*&/.test(body.slice(m.index + m[0].length,
                                                     m.index + m[0].length + 40));
    if (!joins) continue;
    for (let k = last; k < m.index; k++) { out += body[k]; map.push(bmap[k]); }
    const lit = `"${value}"`;
    for (let k = 0; k < lit.length; k++) { out += lit[k]; map.push(bmap[m.index]); }
    last = m.index + m[0].length;
  }
  for (let k = last; k < body.length; k++) { out += body[k]; map.push(bmap[k]); }
  return { body: out, map };
}

/**
 * Strip comments and splice adjacent string literals, keeping a map back to source offsets.
 *
 * @returns {{text:string, map:number[], spliced:string, smap:number[],
 *            resolved:string, rmap:number[]}}
 *          `map[i]` is the source index of output character `i`
 */
function codeView(text) {
  const lines = text.split('\n');
  let out = '';
  const map = [];
  let at = 0;
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const keep = /^\s*##?(\s|$)/.test(raw) ? '' : stripComment(raw);
    for (let k = 0; k < keep.length; k++) { out += keep[k]; map.push(at + k); }
    out += '\n'; map.push(at + raw.length);
    at += raw.length + 1;
  }
  // SPLICE: `"…" & "…"` becomes one literal. Done on the whole text so the operands may
  // sit on different lines, with the offset map carried through so a finding still names
  // the line the concatenation started on.
  const s = spliceJoins(out, map);
  // …AND THE SAME JOIN WITH A NAMED OPERAND, which is a second body rather than a second
  // rule: resolve, then splice with exactly the machinery above.
  const r = resolveConcatOperands(out, map);
  const rs = spliceJoins(r.body, r.map);
  return { text: out, map, spliced: s.body, smap: s.map,
           resolved: rs.body, rmap: rs.map };
}

/** the source line number (1-based) of a source character offset */
function lineAt(text, offset) {
  let n = 1;
  for (let k = 0; k < offset && k < text.length; k++) if (text[k] === '\n') n++;
  return n;
}

/**
 * Every place `text` names a chain, a VM, a fee token or an ecosystem language.
 *
 * @param {string} text   the reader's source
 * @param {{term:string, kind:string}[]} terms  the vocabulary, from the census
 * @returns {{violations:{term:string,kind:string,line:number,spliced:boolean,text:string}[],
 *            commentOccurrences:number}}
 */
export function chainVocabularyLiterals(text, terms) {
  const view = codeView(text);
  const srcLines = text.split('\n');
  const violations = [];
  let commentOccurrences = 0;
  const seen = new Set();
  /** every admitted match of one term in one body, as {index} */
  const matches = (body, term) => {
    const re = new RegExp(term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
    const out = [];
    let m;
    while ((m = re.exec(body)) !== null) {
      const before = m.index === 0 ? '' : body[m.index - 1];
      const after = body[m.index + m[0].length] ?? '';
      const startsUpper = /[A-Z]/.test(m[0][0]);
      const openBoundary = before === '' || !/[A-Za-z0-9]/.test(before)
                           || (startsUpper && /[a-z0-9]/.test(before));
      if (openBoundary && !/[a-z]/.test(after)) out.push(m.index);
    }
    return out;
  };
  for (const { term, kind } of terms) {
    for (const [body, offsets, spliced] of
         [[view.text, view.map, false], [view.spliced, view.smap, true],
          [view.resolved, view.rmap, true]]) {
      for (const idx of matches(body, term)) {
        const line = lineAt(text, offsets[idx] ?? 0);
        const key = `${term}@${line}`;
        if (seen.has(key)) continue;
        seen.add(key);
        violations.push({ term, kind, line, spliced,
                          text: (srcLines[line - 1] ?? '').trim().slice(0, 100) });
      }
    }
    // The comment half, counted rather than named: it is the figure a caller reports so a
    // note about it cannot go stale, and it is deliberately not a violation.
    for (let i = 0; i < srcLines.length; i++) {
      const codeLine = /^\s*##?(\s|$)/.test(srcLines[i]) ? '' : stripComment(srcLines[i]);
      if (matches(srcLines[i], term).length > 0 && matches(codeLine, term).length === 0) {
        commentOccurrences++;
      }
    }
  }
  violations.sort((a, b) => a.line - b.line || (a.term < b.term ? -1 : 1));
  return { violations, commentOccurrences };
}

/** the extraction as plain sorted data, for comparison and for printing */
export function flatten(consumed) {
  const out = {};
  for (const [c, m] of [...consumed].sort((a, b) => a[0] < b[0] ? -1 : 1)) {
    out[c] = {};
    for (const [k, v] of [...m].sort((a, b) => a[0] < b[0] ? -1 : 1)) out[c][k] = v.access;
  }
  return out;
}
