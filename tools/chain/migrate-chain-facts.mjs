// migrate-chain-facts.mjs — bring a committed capture forward onto §5.3's stated facts.
//
//   node tools/chain/migrate-chain-facts.mjs [--write] [<snapshot-dir> …]
//
// ── WHAT IT ADDS, AND WHY A COMMITTED CAPTURE NEEDS IT ────────────────────────────────
//
// Six facts about the chain a capture came from used to be constants inside the READER
// (`Data-Contract.md` §5.3). They are now stated by the producer, which is where they were
// always facts, and the producers in this tree write them from
// `tools/chain/lib/producer-facts.mjs`. The committed captures were written before that, so
// they state none of them — and the reader refuses a snapshot that states none rather than
// choosing on a producer's behalf, which is the whole point.
//
// These captures CANNOT BE RETAKEN. A transaction body prunes about half an hour after it
// lands, so re-capturing is permanently unavailable and the only way forward is to add what
// the producer would now write. Every value this tool writes comes from
// `producer-facts.mjs` — the same module the live producers import — so a migrated capture
// and a fresh one state the same facts from the same source, and nothing is invented here.
//
//   snapshot.json   provenance.recorder, provenance.prestateStrategy
//                   transactions[].cost      — §2.3's VECTOR, from the row's own fee
//                   transactions[].executions — the execution partition, one entry
//   sources/*.json  bundles[].language
//   artifact-resolution.json
//                   transactions[].positions.schema
//
// `positions/*.json` already state their own `schema`; they are checked and reported rather
// than edited, so a stream that did not would be named instead of silently skipped.
//
// ── WHAT IT DOES NOT DO, AND THESE ARE THE LOAD-BEARING RESTRICTIONS ──────────────────
//
//   * IT HOLDS BACK THE SUBJECTS NOTHING INGESTS. Two of the six committed snapshots exist
//     to hold a SHAPE the reader's older-token path is checked against, and no producer
//     reads either — so §5.3's facts buy them nothing and cost them their untouched-ness.
//     They are named in `HELD_OUT` with a reason apiece and the override has to be typed.
//   * IT DOES NOT TOUCH THE `format` TOKEN, in either direction. The facts it adds are
//     required at every token this reader reads, so there is no token that means "carries
//     them" and no token that means "does not" — and promoting a held-out `@1` subject is
//     something §5.2a forbids a tool from doing at all.
//   * IT DOES NOT REPLACE `transactionFee`. The row keeps the receipt's own field beside
//     the vector derived from it: a snapshot is the record of what the node said, and
//     deleting the field the node's receipt used would make the capture a worse record of
//     it to save a duplicated number.
//   * IT IS IDEMPOTENT AND IT SAYS SO. A file that already states a fact is left exactly
//     as it is, byte for byte, and counted as `already`. A second run over a migrated
//     corpus therefore writes nothing, which is what makes it safe to run from a check.
//   * IT REFUSES RATHER THAN SKIPS. An unparseable file, a row with no `transactionFee` to
//     derive a figure from, or a `positions` stream stating no `schema` is reported and
//     makes the run exit non-zero. A migration that quietly passed over what it could not
//     handle would report success over a corpus it had half-converted.
//
// Dry by default: it prints what it would change and writes nothing without `--write`.

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { RECORDER, PRESTATE_STRATEGY, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA,
         costVectorForRow, executionsForRow } from './lib/producer-facts.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

/**
 * The captures this tool migrates: the ones a producer in this repository INGESTS.
 *
 * `refusal-selftest.mjs` enumerates six committed snapshots. Three of them are held out of
 * `migrate-refusal-reasons.mjs` deliberately, and §5.2a's rule about hold-outs is a rule
 * about migration tools in general and not about that one tool: a migration must carry an
 * explicit hold-out, an explicit override, and a record in each held-out artifact of why it
 * is frozen. So the hold-out is stated HERE, with its reason per file, rather than being a
 * list somebody assembled from what happened to be convenient.
 */
const DEFAULT_DIRS = Object.freeze([
  'client/fixtures/chain/aztec',
  'client/fixtures/chain/aztec-testnet',
  'client/fixtures/chain/aztec-testnet-frames',
  // INGESTED, and therefore migrated despite being a held-out `@1` subject — see the
  // hold-out note below and `HELD-AT-V1.md` beside the file, which records what changed.
  'tests/fixtures/chain-snapshots/aztec-mainnet-live',
]);

/**
 * The two committed snapshots this tool does NOT touch, and why each is left alone.
 *
 * Both are `@1` hold-outs and NEITHER IS INGESTED BY ANYTHING — that is the test, not their
 * hold-out status. §5.3's facts are required of a snapshot a producer READS; a subject that
 * exists to hold a SHAPE the reader's older-token path is checked against gains nothing from
 * them and loses its untouched-ness. Adding members to an artifact to satisfy a rule it
 * never meets is the churn §5.2a's hold-out rule exists to prevent.
 *
 * `tests/fixtures/chain-snapshots/aztec-mainnet-live` is the third `@1` hold-out and is NOT
 * here, because it IS ingested — by `tests/tchainsnapshot.nim` and by the byte-identity
 * recipe's six trees — so the reader refuses it without the facts and there is no version of
 * this change in which it stays untouched. `HELD-AT-V1.md` beside it records exactly what
 * this tool added, so the file's claim about itself stays true.
 */
const HELD_OUT = Object.freeze({
  'client/fixtures/noir-frames':
    'not a snapshot and ingested by nothing: it carries no `window`, no `blocks` and no '
    + '`counts`, and it is the `@1` subject for the shape with no untraced rows at all',
  'fixtures/chain-artifacts/aztec-testnet':
    'the artifact capture: ingested by nothing, and the `@1` subject for untraced rows '
    + 'carrying no `refusalReason`',
});

const argv = process.argv.slice(2);
const write = argv.includes('--write');
const includeHeldOut = argv.includes('--include-held-out');
const dirs = argv.filter((a) => !a.startsWith('--'));
const asked = dirs.length ? dirs : DEFAULT_DIRS;
// THE HOLD-OUT IS ENFORCED ON AN EXPLICIT ARGUMENT TOO, not only on the default list. A
// hold-out that a `<dir>` argument walks straight past is intent living in a default, which
// is the failure §5.2a names: "intent that lives only in the tool is intent the next glob
// walks past". The override exists and it has to be typed.
const targets = [];
for (const d of asked) {
  const why = HELD_OUT[d.replace(/\/+$/, '')];
  if (why && !includeHeldOut) {
    console.error(`HELD OUT  ${d} — ${why}. Pass --include-held-out to override.`);
    continue;
  }
  targets.push(join(root, d));
}

let changed = 0, already = 0, problems = 0;
const say = (s) => console.error(s);
const bad = (s) => { problems++; console.error(`  PROBLEM  ${s}`); };

/** Read a JSON file, or report it and return null. The `null` is never treated as empty. */
const indents = new Map();
function load(path) {
  try {
    const text = readFileSync(path, 'utf8');
    const doc = JSON.parse(text);
    indents.set(path, indentOf(text, path));
    return doc;
  } catch (e) {
    bad(`${relative(root, path)} did not parse: ${e.message}`);
    return null;
  }
}
const indentFor = (path) => indents.get(path) ?? null;

/**
 * Write with the indentation THIS FILE already uses, detected rather than assumed.
 *
 * Most committed captures are one-space, and writing them all that way reformatted a
 * two-space `sources/` bundle from end to end on the first run of this tool: 51 lines
 * added and 50 removed to add one member. A whole-file reformat inside a migration is
 * the diff nobody reads, and it hides the one line that mattered — so the indent comes
 * from the file and a file whose indent cannot be read is left alone and reported.
 */
function indentOf(text, path) {
  const m = /\n( +)"/.exec(text);
  if (!m) { bad(`${relative(root, path)}: cannot read its own indentation`); return null; }
  return m[1].length;
}

function save(path, doc, indent) {
  if (indent === null) return;
  if (write) writeFileSync(path, JSON.stringify(doc, null, indent) + '\n');
}

/**
 * Insert `key: value` into `obj` immediately after `after`, or at the end when `after` is
 * absent. Position is cosmetic and the diff is not: a member appended to the end of a row
 * of thirty puts the change where a reviewer has to go looking for it.
 */
function insertAfter(obj, after, entries) {
  const out = {};
  let placed = false;
  for (const [k, v] of Object.entries(obj)) {
    out[k] = v;
    if (k === after) { for (const [ek, ev] of entries) out[ek] = ev; placed = true; }
  }
  if (!placed) for (const [ek, ev] of entries) out[ek] = ev;
  return out;
}

for (const dir of targets) {
  const rel = relative(root, dir);
  const snapPath = join(dir, 'snapshot.json');
  if (!existsSync(snapPath)) { bad(`${rel}/snapshot.json does not exist`); continue; }
  say(`\n${rel}`);
  const snap = load(snapPath);
  if (snap === null) continue;

  // ---- provenance --------------------------------------------------------------------
  let snapTouched = false;
  const prov = snap.provenance;
  if (!prov || typeof prov !== 'object') {
    bad(`${rel}/snapshot.json carries no provenance object`);
  } else {
    const add = [];
    if (prov.recorder === undefined) add.push(['recorder', { ...RECORDER }]);
    if (prov.prestateStrategy === undefined) add.push(['prestateStrategy', PRESTATE_STRATEGY]);
    if (add.length) {
      snap.provenance = insertAfter(prov, 'endpoint', add);
      snapTouched = true;
      say(`  provenance += ${add.map(([k]) => k).join(', ')}`);
    } else {
      say('  provenance already states recorder and prestateStrategy');
    }
  }

  // ---- rows --------------------------------------------------------------------------
  const rows = Array.isArray(snap.transactions) ? snap.transactions : [];
  let rowsCost = 0, rowsExec = 0, rowsAlready = 0;
  const migrated = rows.map((row) => {
    const add = [];
    if (row.cost === undefined) {
      if (row.transactionFee === undefined) {
        bad(`${rel}: row ${String(row.txHash).slice(0, 12)} carries no transactionFee, so `
            + 'there is no figure to state a cost vector from');
        return row;
      }
      add.push(['cost', costVectorForRow(row.transactionFee)]);
      rowsCost++;
    }
    if (row.executions === undefined) { add.push(['executions', executionsForRow()]); rowsExec++; }
    if (!add.length) { rowsAlready++; return row; }
    return insertAfter(row, 'transactionFee', add);
  });
  if (rowsCost || rowsExec) {
    snap.transactions = migrated;
    snapTouched = true;
    say(`  rows: +cost on ${rowsCost}, +executions on ${rowsExec}, `
        + `${rowsAlready} already stated (of ${rows.length})`);
  } else {
    say(`  rows: all ${rows.length} already state cost and executions`);
  }
  if (snapTouched) { save(snapPath, snap, indentFor(snapPath)); changed++; } else { already++; }

  // ---- source bundles ----------------------------------------------------------------
  const srcDir = join(dir, 'sources');
  if (existsSync(srcDir)) {
    let bAdd = 0, bAlready = 0, files = 0;
    for (const f of readdirSync(srcDir).filter((x) => x.endsWith('.json')).sort()) {
      const p = join(srcDir, f);
      const doc = load(p);
      if (doc === null) continue;
      files++;
      let touched = false;
      for (const b of (Array.isArray(doc.bundles) ? doc.bundles : [])) {
        if (b.language === undefined) { b.language = POSITION_LANGUAGE; bAdd++; touched = true; }
        else bAlready++;
      }
      if (touched) { save(p, doc, indentFor(p)); changed++; } else { already++; }
    }
    say(`  sources/: ${files} file(s), +language on ${bAdd} bundle(s), ${bAlready} already`);
  }

  // ---- the post-hoc positions inside the artifact-resolution sidecar -----------------
  const arRel = snap.artifactResolution ?? 'artifact-resolution.json';
  const arPath = join(dir, arRel);
  if (existsSync(arPath)) {
    const doc = load(arPath);
    if (doc !== null) {
      let pAdd = 0, pAlready = 0;
      for (const t of (Array.isArray(doc.transactions) ? doc.transactions : [])) {
        if (!t.positions || typeof t.positions !== 'object') continue;
        if (t.positions.unavailable !== undefined) continue;   // not a stream at all
        if (t.positions.schema === undefined) {
          t.positions = insertAfter(t.positions, null,
                                    [['schema', POSITION_STREAM_SCHEMA]]);
          // …at the FRONT, which `insertAfter(null)` cannot do, so reorder here: a schema
          // token belongs where a reader looks for it first, and every other stream in
          // this tree carries it as its first member.
          t.positions = { schema: POSITION_STREAM_SCHEMA,
                          ...Object.fromEntries(Object.entries(t.positions)
                            .filter(([k]) => k !== 'schema')) };
          pAdd++;
        } else pAlready++;
      }
      if (pAdd) { save(arPath, doc, indentFor(arPath)); changed++; } else { already++; }
      say(`  ${arRel}: +schema on ${pAdd} post-hoc stream(s), ${pAlready} already`);
    }
  }

  // ---- and the captured position streams, CHECKED rather than edited -----------------
  const posDir = join(dir, 'positions');
  if (existsSync(posDir)) {
    let ok = 0;
    for (const f of readdirSync(posDir).filter((x) => x.endsWith('.json')).sort()) {
      const doc = load(join(posDir, f));
      if (doc === null) continue;
      if (typeof doc.schema === 'string' && doc.schema.length > 0) ok++;
      else bad(`${rel}/positions/${f} states no schema; the reader republishes the `
               + 'stream\'s own token and will refuse this');
    }
    say(`  positions/: ${ok} stream(s) already state their schema`);
  }
}

say(`\n${write ? 'WROTE' : 'WOULD WRITE'} ${changed} file(s); ${already} already current; `
    + `${problems} problem(s)`);
if (!write) say('Dry run — pass --write to apply.');
process.exit(problems ? 1 : 0);
