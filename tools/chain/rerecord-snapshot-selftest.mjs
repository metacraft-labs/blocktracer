// Does the re-record tool decide? One arm per refusal it owes, plus the base
// case so the others are not vacuous.
//
// THE DRIVER IS A STUB, as in `replay-selftest`'s case 12 and 13: the real one
// needs a node, a network and a wasm, and an arm that cannot run is an arm that
// passes for the wrong reason. Each arm writes a `#!/bin/sh` script that plays
// the part of `replay_settled_transaction.mjs` — writing a container, or not —
// and the tool is driven over a synthetic snapshot directory.

import { mkdtemp, mkdir, writeFile, chmod, readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'rerecord-snapshot.mjs');

const CTFS = Buffer.from([0xc0, 0xde, 0x72, 0xac, 0xe2]);
/** A container whose header says what we want it to say. */
function container(version, { profile = null, size = 4096 } = {}) {
  const b = Buffer.alloc(size, 0x41);
  CTFS.copy(b, 0);
  b[5] = version;
  if (profile !== null) b[16] = profile;
  return b;
}

function run(args, env = {}) {
  return new Promise((res) => {
    execFile(process.execPath, [TOOL, ...args], { env: { ...process.env, ...env } },
      (err, stdout, stderr) => res({ code: err?.code ?? 0, stdout, stderr }));
  });
}

/** A snapshot dir with one traced transaction and one untraced one. */
async function arena(dir, { version = 3, recording = { bytes: 4096, steps: 7, logEvents: 5 } } = {}) {
  await mkdir(join(dir, 'snap', 'ct'), { recursive: true });
  await writeFile(join(dir, 'snap', 'ct', '0xaa.ct'), container(version));
  // ONE SPACE, as the real snapshots are written. `JSON.stringify(_, null, 2)`
  // on the aztec snapshot reformatted all 41,191 lines around three changed
  // numbers, so the indent is part of what this tool must preserve.
  await writeFile(join(dir, 'snap', 'snapshot.json'), `${JSON.stringify({
    format: 'test/v1',
    provenance: { kind: 'live-capture', endpoint: 'http://node.invalid' },
    transactions: [
      { txHash: '0xaa', blockNumber: 10, txIndexInBlock: 0, revertCode: 0,
        container: 'ct/0xaa.ct', recording },
      { txHash: '0xbb', blockNumber: 11, txIndexInBlock: 0, revertCode: 0 },
    ],
  }, null, 1)}\n`);
}

/**
 * A stub driver. `behaviour` decides what it does with `--ct`:
 *   'write'   write a container of `version`/`profile` and print a JSON report
 *   'nothing' print a report and write no file
 *   'moved'   write, but report a different revertCode than the snapshot's
 */
async function stubDriver(dir, behaviour, { version = 6, profile = 1, size = 2048,
                                            recording = {}, revertCode = 0 } = {}) {
  const stub = join(dir, `stub-${behaviour}`);
  // SHAPED AS THE DRIVER PRINTS IT, not as `decideOutcome` returns it. The two
  // differ — `replayed` is `{ revertCode }` on the wire and a boolean on the
  // decided row — and a stub written to the second shape made every arm here
  // report REFUSED while the container it wrote was perfectly good.
  const payload = JSON.stringify({
    l2BlockNumber: 10, txIndexInBlock: 0, preStateReadAt: 9,
    contractReferenceBlock: 9, rounds: 1, seedSize: 4096, instructionsExecuted: 7,
    published: { revertCode }, replayed: { revertCode },
    verdict: { reproduced: true, matched: 1, mismatched: 0 },
    mismatches: [],
    recording: {
      bytes: size, steps: 7, logEvents: 6,
      // A field the snapshot's recording block does not have and no list in the
      // tool anticipates — long enough that it must print as a SHAPE.
      contractRungs: [{ address: '0xfeed', rung: 3, reason: 'x'.repeat(200) }],
      ...recording,
    },
    roots: {}, rootsAnyAgree: true, skipped: [],
  });
  const hdr = [...container(version, { profile, size: 17 })].slice(0, 17)
    .map((b) => `\\x${b.toString(16).padStart(2, '0')}`).join('');
  const writeIt = behaviour === 'nothing' ? '' :
    // `printf` the 17-byte header then pad with A's to `size`.
    `ct=""\nwhile [ "$#" -gt 0 ]; do\n  [ "$1" = "--ct" ] && ct="$2"\n  shift\ndone\n`
    + `printf '${hdr}' > "$ct"\n`
    + `i=17\nwhile [ "$i" -lt ${size} ]; do printf 'A' >> "$ct"; i=$((i+1)); done\n`;
  await writeFile(stub, `#!/bin/sh\n${writeIt}cat <<'JSON'\n${payload}\nJSON\nexit 0\n`);
  await chmod(stub, 0o755);
  return stub;
}

export async function selftest() {
  const dir = await mkdtemp(join(tmpdir(), 'rerecord-arena-'));
  let pass = 0, fail = 0;
  const ck = (claim, ok) => {
    if (ok) { pass++; console.log(`  [OK]     ${claim}`); }
    else { fail++; console.log(`  [FAILED] ${claim}`); }
  };

  const common = async (d, stub, extra = []) => run([
    '--dir', join(d, 'snap'), '--runtime', d, '--avm', stub, '--ct-writer', stub,
    '--node', stub, '--url', 'http://node.invalid', ...extra,
  ]);

  // ── base case: it re-records, installs, and says what moved ──────────────
  {
    const d = await mkdtemp(join(tmpdir(), 'rr-base-'));
    await arena(d);
    const stub = await stubDriver(d, 'write');
    const r = await common(d, stub, ['--compact-threshold', '100000']);
    ck('a clean re-record exits 0', r.code === 0);
    ck('…and installs the new container', existsSync(join(d, 'snap', 'ct', '0xaa.ct')));
    const snap = JSON.parse(await readFile(join(d, 'snap', 'snapshot.json'), 'utf8'));
    ck('…and the row\'s recording block is the producer\'s new one',
       snap.transactions[0].recording.bytes === 2048);
    ck('…and a provenance entry records that these bytes are not the capture\'s',
       Array.isArray(snap.provenance.rerecordings) && snap.provenance.rerecordings.length === 1);
    ck('…naming the container versions it produced',
       JSON.stringify(snap.provenance.rerecordings[0].containerVersions) === '{"v6":1}');
    ck('…and the threshold it was asked for',
       snap.provenance.rerecordings[0].compactThreshold === 100000);
    const text = await readFile(join(d, 'snap', 'snapshot.json'), 'utf8');
    ck('the file keeps ITS OWN indentation, so the diff is the change and not a reformat',
       /^\{\n "format"/.test(text));
    ck('the CHANGED recording field is printed by name, not absorbed',
       /recording\.logEvents: 5 -> 6/.test(r.stdout));
    ck('the version move is printed on both sides',
       /was 4096 B, container 3/.test(r.stdout) && /now 2048 B, container 6 profile 1/.test(r.stdout));
    ck('a field NO list anticipated is reported too, by its shape when it is long',
       /recording\.contractRungs: undefined -> \[1 entry, \d+ B\]/.test(r.stdout));
    ck('THE CONTROL: the untraced transaction is not a subject',
       /1 traced transaction\(s\)/.test(r.stdout));
    await rm(d, { recursive: true, force: true });
  }

  // ── a driver that writes nothing installs nothing ────────────────────────
  {
    const d = await mkdtemp(join(tmpdir(), 'rr-none-'));
    await arena(d);
    const stub = await stubDriver(d, 'nothing');
    const r = await common(d, stub);
    ck('a subject that did not re-record exits 1', r.code === 1);
    const snap = JSON.parse(await readFile(join(d, 'snap', 'snapshot.json'), 'utf8'));
    ck('…and NOTHING was written: the snapshot is untouched',
       snap.provenance.rerecordings === undefined && snap.transactions[0].recording.logEvents === 5);
    ck('…and the refusal says why a partial corpus is not an option',
       /half at one container version/.test(r.stderr));
    await rm(d, { recursive: true, force: true });
  }

  // ── a chain fact that moved is a moved SUBJECT, not a format change ──────
  {
    const d = await mkdtemp(join(tmpdir(), 'rr-moved-'));
    await arena(d);
    const stub = await stubDriver(d, 'write', { revertCode: 1 });
    const r = await common(d, stub);
    ck('a replay that disagrees about a chain fact is REFUSED', r.code === 1);
    ck('…and the conflicting field is named with both values',
       /CHAIN FACT MOVED: revertCode snapshot=0 replay=1/.test(r.stdout));
    const snap = JSON.parse(await readFile(join(d, 'snap', 'snapshot.json'), 'utf8'));
    ck('…and nothing was installed', snap.provenance.rerecordings === undefined);
    await rm(d, { recursive: true, force: true });
  }

  // ── --dry-run writes nothing, and says so ────────────────────────────────
  {
    const d = await mkdtemp(join(tmpdir(), 'rr-dry-'));
    await arena(d);
    const stub = await stubDriver(d, 'write');
    const r = await common(d, stub, ['--dry-run']);
    ck('--dry-run exits 0', r.code === 0);
    ck('…and installs nothing', /NOT installed/.test(r.stdout));
    const snap = JSON.parse(await readFile(join(d, 'snap', 'snapshot.json'), 'utf8'));
    ck('…and the snapshot is untouched', snap.provenance.rerecordings === undefined);
    await rm(d, { recursive: true, force: true });
  }

  // ── a snapshot with no traced transaction is a refusal, not a no-op ──────
  {
    const d = await mkdtemp(join(tmpdir(), 'rr-empty-'));
    await mkdir(join(d, 'snap'), { recursive: true });
    await writeFile(join(d, 'snap', 'snapshot.json'), `${JSON.stringify({
      provenance: { endpoint: 'http://node.invalid' },
      transactions: [{ txHash: '0xcc', blockNumber: 1 }],
    })}\n`);
    const stub = await stubDriver(d, 'write');
    const r = await common(d, stub);
    ck('a snapshot naming no container is REFUSED rather than reported clean',
       r.code === 2 && /names no transaction carrying a container/.test(r.stderr));
    await rm(d, { recursive: true, force: true });
  }

  await rm(dir, { recursive: true, force: true });
  console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} of ${pass + fail} assertion(s)`);
  return fail === 0 ? 0 : 1;
}
