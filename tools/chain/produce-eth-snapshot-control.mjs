#!/usr/bin/env node
//
// produce-eth-snapshot-control.mjs — THE CONTROL THAT MAKES A GREEN CONFORMANCE RUN A
// VERDICT RATHER THAN A DEFAULT.
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────────────────
//
// `blocktracer-conformance --snapshot <tree>` printing `VERDICT: this tree conforms` is
// evidence about the tree only if the same command, on the same tree, with ONE member
// changed, refuses — and refuses by naming the §5 rule that member belongs to. Without
// that arm a green is indistinguishable from a checker that accepts everything, which is
// the failure shape Data-Contract.md §5 spends most of its length recording instances of.
// Chain-Delivery DEL-5's verification entry `test_the_snapshot_passes_the_released_kit`
// names this control in as many words: "a single-member mutation of the snapshot is
// refused by name and cites its §5 rule id, so acceptance is a verdict and not a default".
//
// EVERY ARM IS A SINGLE MEMBER. Not a shape, not a file, not a section — one member of one
// object, changed or removed, with everything else byte-identical to a tree that was just
// accepted. That is what makes the cited rule an ATTRIBUTION: a mutation that broke three
// things would be refused by whichever rule the reader reached first and would say nothing
// about which member the rule is actually about.
//
// ── WHY IT IS NOT IN `just chain-selftest` ────────────────────────────────────────────
//
// It needs two things the repository does not carry and will not: a CAPTURE (the `.ct`
// ban refuses an added container, and the ban is right — a committed recording pins a
// recorder version nothing tracks) and a RELEASED KIT (`conformance-kit-release/` is a
// gitignored build artifact). A suite wired into a recipe that cannot find its subjects is
// a suite that reports SKIP forever, which is the state `chain-health`'s own header argues
// against at length. So this is a recipe you run with its subjects named, exactly like
// `just chain-health-corpus --container-reader …`, and it is three-state: 0 every arm held,
// 1 an arm did not, 2 a subject is missing and NOTHING WAS MEASURED.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// There are none. The subject is a real snapshot a real producer wrote from a real
// transaction, the checker is the released binary, and each arm is that same tree copied
// and edited in one place. The mutants are the opposite of mocks: they are the real
// artifact minus one true thing.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node tools/chain/produce-eth-snapshot-control.mjs \
//     --snapshot <tree produce-eth-snapshot.mjs wrote> \
//     --kit      <directory `just conformance-kit-release` staged> \
//     [--work <scratch dir>] [--keep]

import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync }
  from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const argv = process.argv.slice(2);
const flag = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i === -1 ? d : argv[i + 1];
};
const has = (n) => argv.includes(`--${n}`);

const snapshot = flag('snapshot');
const kit = flag('kit');
const keep = has('keep');

if (!snapshot || !kit) {
  console.error('usage: produce-eth-snapshot-control.mjs --snapshot DIR --kit DIR '
                + '[--work DIR] [--keep]');
  process.exit(2);
}
const conformance = join(kit, 'bin', 'blocktracer-conformance');
for (const [what, p] of [['snapshot tree', join(snapshot, 'snapshot.json')],
                         ['released kit binary', conformance]]) {
  if (!existsSync(p)) {
    console.error(`NOT MEASURED: no ${what} at ${p}. This control has subjects or it has `
                  + `nothing; it does not report a pass without them.`);
    process.exit(2);
  }
}

const work = flag('work') ?? mkdtempSync(join(tmpdir(), 'eth-snapshot-control-'));
mkdirSync(work, { recursive: true });

/** Run the released kit over one tree. Returns `{rc, rule, out}`; rc is the COMMAND'S. */
function check(tree) {
  let out = '';
  let rc = 0;
  try {
    out = execFileSync(conformance, ['--snapshot', resolve(tree)],
                       { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    rc = e.status ?? 1;
    out = `${e.stdout ?? ''}${e.stderr ?? ''}`;
  }
  const m = /rule:\s+(S5-[A-Z0-9-]+)/.exec(out);
  return { rc, rule: m ? m[1] : null, out };
}

/**
 * THE ARMS. Each is one member, named by the path it lives at, with the rule the contract
 * states for it. `at` walks the JSON; `set` writes a value and `del` removes the member —
 * nothing here edits two places.
 */
const TRACED = '0xf6998cac9f5d2843729743b866bdc4b09bd119774bbec5e56f69f8819f2b71aa';

const arms = [
  // file, what, mutate(json), expected rule
  ['snapshot.json', 'counts.transactions understated by one',
   (s) => { s.counts.transactions -= 1; }, 'S5-COUNTS-ROWS'],
  ['snapshot.json', 'counts.accountedFor no longer reconciling',
   (s) => { s.counts.accountedFor -= 1; }, 'S5-COUNTS-RECONCILE'],
  ['snapshot.json', 'the `refusalReason` taken off ONE untraced row',
   (s) => { delete s.transactions.find((t) => t.outcome === 'not-attempted').refusalReason; },
   'S5-REFUSALREASON-REQUIRED'],
  ['snapshot.json', 'the `reason` emptied on ONE untraced row',
   (s) => { s.transactions.find((t) => t.outcome === 'not-attempted').reason = ''; },
   'S5-REASON-REQUIRED'],
  ['snapshot.json', '`containerBytes` off by one from the file on disk',
   (s) => { s.transactions.find((t) => t.txHash === TRACED).containerBytes += 1; },
   'S5-CONTAINER-BYTES'],
  ['snapshot.json', 'an `outcome` token outside the closed set',
   (s) => { s.transactions.find((t) => t.txHash === TRACED).outcome = 'replayed-ish'; },
   'S5-OUTCOME-CLOSED'],
  ['snapshot.json', 'a `refusalReason` outside the closed set',
   (s) => {
     s.transactions.find((t) => t.outcome === 'not-attempted').refusalReason = 'ran-out-of-time';
   }, 'S5-REFUSALREASON-CLOSED'],
  ['snapshot.json', 'the cost VECTOR emptied on the traced row',
   (s) => { s.transactions.find((t) => t.txHash === TRACED).cost = []; },
   'S5-COST-VECTOR'],
  ['snapshot.json', 'the `recording` block removed from the traced row',
   (s) => { delete s.transactions.find((t) => t.txHash === TRACED).recording; },
   'S5-ROW-MEMBERS-REQUIRED'],
  ['snapshot.json', '`provenance.chain` removed',
   (s) => { delete s.provenance.chain; }, 'S5-CHAIN-NAMED'],
  ['snapshot.json', '`provenance.prestateStrategy` spelled off the closed set',
   (s) => { s.provenance.prestateStrategy = 'replay-the-preceding'; },
   'S5-PRESTATE-CLOSED'],
  ['snapshot.json', '`provenance.recorder` removed',
   (s) => { delete s.provenance.recorder; }, 'S5-RECORDER-STATED'],
  ['snapshot.json', 'the `format` token bumped to one no reader states',
   (s) => { s.format = 'blocktracer/chain-snapshot@3'; }, 'S5-FORMAT-UNKNOWN'],
  // THESE TWO ARMS ARE A PAIR AND THE PAIRING IS A MEASUREMENT, NOT A STYLE.
  //
  // The first expectation written here was "`counts` removed whole => S5-COUNTS-PRESENT",
  // and it was WRONG — measured 2026-10-08: the reader cites `S5-MEMBERS-REQUIRED`. Both
  // rules are about `counts` and they do not overlap. `S5-MEMBERS-REQUIRED` is generated
  // from §5.2's required set and runs FIRST (`ingest.nim` ~661), so an ABSENT `counts` can
  // never reach `S5-COUNTS-PRESENT` (~685) at all; what that rule is about is a `counts`
  // that is PRESENT and is not an object. So the two arms below are the two different
  // defects, each citing its own rule, and the expectation was corrected rather than the
  // assertion relaxed.
  ['snapshot.json', '`counts` present and not an object',
   (s) => { s.counts = 208; }, 'S5-COUNTS-PRESENT'],
  ['snapshot.json', '`counts` removed whole — the generated required-member walk, which '
   + 'runs first and SHADOWS the rule above',
   (s) => { delete s.counts; }, 'S5-MEMBERS-REQUIRED'],
  ['snapshot.json', '`window` removed whole',
   (s) => { delete s.window; }, 'S5-MEMBERS-REQUIRED'],
  ['snapshot.json', 'a second execution left without its own reason on the traced row',
   (s) => {
     s.transactions.find((t) => t.txHash === TRACED).executions
       .push({ selector: 'also-this-one' });
   }, 'S5-EXECUTIONS-ONE-TRACED'],
  [`instructions/${TRACED}.json`, 'the instruction listing short by one step',
   (s) => { s.steps -= 1; }, 'S5-INSTRUCTIONS-AGREE'],
  [`positions/${TRACED}.json`, 'the position stream short by one step',
   (s) => { s.steps -= 1; }, 'S5-POSITIONS-AGREE'],
  [`positions/${TRACED}.json`, 'the position stream stating no schema of its own',
   (s) => { delete s.schema; }, 'S5-POSITIONS-SCHEMA'],
  [`positions/${TRACED}.json`, 'one position column one element short',
   (s) => { s.line.pop(); }, 'S5-POSITIONS-COLUMNS'],
  [`calltrace/${TRACED}.json`, 'the call trace declaring one frame more than the recording opened',
   (s) => { s.frames += 1; }, 'S5-CALLTRACE-AGREE'],
  [`calltrace/${TRACED}.json`, 'a frame marked folded with nothing behind it',
   (s) => { s.frame[1].foldedBy = 'nothing-at-all'; s.frame[1].hiddenDescendants = 0; },
   'S5-CALLTRACE-FOLD-NONEMPTY'],
  [`sources/${TRACED}.json`, 'the source bundle with no contract-class key',
   (s) => { delete s.bundles[0].codeHash; }, 'S5-BUNDLE-KEYED'],
  [`sources/${TRACED}.json`, 'the source bundle with no files in it',
   (s) => { s.bundles[0].files = {}; }, 'S5-BUNDLE-NONEMPTY'],
  ['artifact-resolution.json', 'the snapshot-wide sidecar naming another chain',
   (s) => { s.chain = 'aztec-testnet'; }, 'S5-SIDECAR-CHAIN'],
  ['artifact-resolution.json', 'the sidecar carrying a version token of its own that nothing states',
   (s) => { s.format = 'blocktracer/artifact-resolution@9'; }, 'S5-SIDECAR-FORMAT-UNKNOWN'],
];

let asserted = 0;
let failing = 0;
const ck = (what, ok, detail = '') => {
  asserted++;
  if (!ok) failing++;
  console.log(`  ${ok ? 'ok    ' : 'FAILED'}  ${what}${detail ? ` — ${detail}` : ''}`);
};

// ── THE GREEN ARM FIRST, because a harness that refuses everything would pass every
// arm below it. The subject is a COPY, so the green and the reds differ in nothing but
// the one member.
const clean = join(work, 'clean');
rmSync(clean, { recursive: true, force: true });
cpSync(snapshot, clean, { recursive: true });
const base = check(clean);
console.log('produce-eth-snapshot-control: the released kit over the tree, and over the '
            + 'same tree one member at a time');
ck('the unmutated copy is ACCEPTED, so a refusal below is about the member and not about '
   + 'the harness', base.rc === 0, `rc ${base.rc}`);
if (base.rc !== 0) {
  console.error(base.out);
  console.error('NOT MEASURED: the clean copy did not pass, so nothing below discriminates.');
  if (!keep) rmSync(work, { recursive: true, force: true });
  process.exit(2);
}

// ── AND THE ONE ARM THAT IS NOT A MUTATION: the tree with its `snapshot.json` taken away
// is refused as a MISSING SUBJECT and not accepted as an empty one.
{
  const gone = join(work, 'no-snapshot-json');
  rmSync(gone, { recursive: true, force: true });
  cpSync(snapshot, gone, { recursive: true });
  rmSync(join(gone, 'snapshot.json'));
  const r = check(gone);
  ck('a tree with no `snapshot.json` is a REFUSAL and not a vacuous pass',
     r.rc !== 0, `rc ${r.rc}`);
}

for (const [i, [file, what, mutate, rule]] of arms.entries()) {
  const dir = join(work, `m${String(i).padStart(2, '0')}`);
  rmSync(dir, { recursive: true, force: true });
  cpSync(snapshot, dir, { recursive: true });
  const target = join(dir, file);
  const json = JSON.parse(readFileSync(target, 'utf8'));
  mutate(json);
  writeFileSync(target, `${JSON.stringify(json, null, 1)}\n`);
  const r = check(dir);
  ck(`${file}: ${what}`,
     r.rc !== 0 && r.rule === rule,
     `rc ${r.rc}, cited ${r.rule ?? '(no rule)'}, expected ${rule}`);
}

console.log('');
console.log(`arm count: ${asserted} (1 green + 1 missing-subject + ${arms.length} `
            + `single-member mutations)`);
const cited = new Set(arms.map((a) => a[3]));
console.log(`distinct §5 rules attributed: ${cited.size}`);
if (!keep) rmSync(work, { recursive: true, force: true });
if (failing > 0) {
  console.log(`produce-eth-snapshot-control: ${failing} failing arm(s)`);
  process.exit(1);
}
console.log('PASS — every single-member mutation is refused by name and cites the rule '
            + 'the contract states for that member, and the unmutated tree is accepted.');
