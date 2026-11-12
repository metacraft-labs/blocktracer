// solana-corpus-census.mjs — RECORDER-SOLANA CXP-SOL-4: WHICH CELLS OF THE DIVERGENCE
// TAXONOMY THE PINNED SOLANA REPLAY FIXTURES COVER, AND WHICH THEY DO NOT.
//
// `spec/Testing/Blockchain-Recorder-Test-Suites.md` §4 asks for coverage "reported per
// cell, so that 'what have we not tested' is answerable rather than a feeling". The pinned
// fixtures are the replay bundles committed under fixtures/chain-inputs/solana-mainnet/,
// each a self-contained transaction plus every account it read. `nix build
// .#sol-capture-tree` replays all of them through the recorder in every deploy build, and
// the divergence check must return `match` for each. This module places each bundle in §4's
// cells as they apply to Solana. A cell no bundle reaches is listed as UNCOVERED with its
// reason, never dropped.
//
// Everything is read from the bundle: the transaction's wire bytes, the chain's own
// metadata (err, logs, inner instructions, loaded addresses) and the accounts with their
// owners. Nothing is fetched.

const NATIVE_LOADER = 'NativeLoader1111111111111111111111111111111';
const UPGRADEABLE = 'BPFLoaderUpgradeab1e11111111111111111111111';
const PRECOMPILES = new Set([
  'Ed25519SigVerify111111111111111111111111111',
  'KeccakSecp256k11111111111111111111111111111',
  'Secp256r1SigVerify1111111111111111111111111',
]);

/** §4's cells as they apply to Solana, in the spec's order, each with what reaches it. */
export const CELLS = Object.freeze([
  ['4.2 type: legacy message', (f) => f.version === 'legacy'],
  ['4.2 type: v0 message', (f) => f.version === 'v0'],
  ['4.2 type: v0 with address lookup tables', (f) => f.lookupTables],
  ['4.3 system: vote transaction', (f) => f.vote],
  ['4.4 builtin: a native program invoked', (f) => f.nativeInvoked],
  ['4.4 precompile: a signature-verify precompile invoked', (f) => f.precompile],
  ['4.5 creation: a program deployed or upgraded', (f) => f.deploy],
  ['4.6 upgrade: an upgradeable-loader program executed', (f) => f.upgradeable],
  ['4.7 nesting: a cross-program invocation (depth 2)', (f) => f.depth >= 2],
  ['4.7 nesting: depth 3 or more', (f) => f.depth >= 3],
  ['4.7 reentrancy: a program invoked while already on the stack', (f) => f.reentrant],
  ['4.8 failure: a custom program error', (f) => f.failure === 'custom'],
  ['4.8 failure: compute budget exhausted', (f) => f.failure === 'compute'],
  ['4.8 failure: any other instruction error', (f) => f.failure === 'other'],
  ['4.8 failure: a program panic', (f) => f.panicked],
]);

/** Why a cell can stay empty on this route, stated where it is known. */
export const UNREACHABLE = Object.freeze({
  "4.1 era: a feature set earlier than the capture's":
    "forward capture replays only the era current while it runs; no RPC serves the state an earlier era's transactions read",
  '4.3 system: vote transaction': 'mainnet blocks carry no vote transactions (0 of 16,180 to 18,534 per 60-slot window, 2026-11-12)',
});

/** The facts one bundle contributes. */
export function factsOf(bundle) {
  const tx = bundle.transactions[0];
  const m = tx.meta ?? {};
  const wire = Buffer.from(tx.wire, 'base64');
  const sigs = wire[0]; // compact-u16; every committed transaction has fewer than 128
  const msg = wire.subarray(1 + 64 * sigs);
  const version = msg[0] & 0x80 ? `v${msg[0] & 0x7f}` : 'legacy';
  const logs = m.logMessages ?? [];
  const stack = [];
  let depth = 0;
  let reentrant = false;
  const invoked = new Set();
  for (const l of logs) {
    const inv = /^Program (\S+) invoke \[(\d+)\]/.exec(l);
    if (inv) {
      const [, program, level] = inv;
      stack.length = Number(level) - 1;
      if (stack.includes(program)) reentrant = true;
      stack.push(program);
      invoked.add(program);
      depth = Math.max(depth, Number(level));
    }
  }
  const owners = new Map(bundle.accounts.filter((a) => a.executable).map((a) => [a.pubkey, a.owner]));
  const errText = m.err ? JSON.stringify(m.err) : '';
  const failure = !m.err ? null
    : /"Custom"/.test(errText) ? 'custom'
      : /ComputationalBudgetExceeded/.test(errText)
        || logs.some((l) => /exceeded CUs meter|consumed \d+ of \d+ compute units.*exceeded/.test(l)) ? 'compute'
        : 'other';
  return {
    signature: tx.signature,
    version,
    lookupTables: ((m.loadedAddresses?.writable?.length ?? 0) + (m.loadedAddresses?.readonly?.length ?? 0)) > 0,
    vote: invoked.has('Vote111111111111111111111111111111111111111'),
    nativeInvoked: [...invoked].some((p) => owners.get(p) === NATIVE_LOADER),
    precompile: [...invoked].some((p) => PRECOMPILES.has(p)),
    deploy: logs.some((l) => /^Program log: (Deployed|Upgraded) program/.test(l)),
    upgradeable: [...invoked].some((p) => owners.get(p) === UPGRADEABLE),
    depth,
    reentrant,
    failure,
    panicked: logs.some((l) => /panicked at/.test(l)),
    activeFeatures: (bundle.features ?? []).filter((f) => f.activatedAt !== null && f.activatedAt <= tx.slot).length,
    slot: tx.slot,
  };
}

/** The census: every cell, covered or not, from a list of bundles. */
export function census(bundles) {
  const facts = bundles.map(factsOf).sort((a, b) => a.signature.localeCompare(b.signature));
  const cells = CELLS.map(([cell, reaches]) => {
    const hits = facts.filter(reaches);
    return hits.length
      ? { cell, covered: hits.length, example: hits[0].signature }
      : { cell, covered: 0, uncovered: UNREACHABLE[cell] ?? 'no pinned fixture reaches it yet' };
  });
  const eras = [...new Set(facts.map((f) => f.activeFeatures))].sort((a, b) => a - b);
  // §4.1 is about eras, not transactions, so its cells are counted over the set: the
  // feature sets the bundles ran under, and the earlier ones none of them did.
  cells.unshift(
    eras.length
      ? { cell: '4.1 era: the feature set active at the capture', covered: eras.length, example: `${eras.join(', ')} active features` }
      : { cell: '4.1 era: the feature set active at the capture', covered: 0, uncovered: 'no bundle' },
    { cell: "4.1 era: a feature set earlier than the capture's", covered: 0, uncovered: UNREACHABLE["4.1 era: a feature set earlier than the capture's"] },
  );
  return {
    format: 'blocktracer/sol-corpus-census@1',
    bundles: facts.length,
    slots: facts.length ? [Math.min(...facts.map((f) => f.slot)), Math.max(...facts.map((f) => f.slot))] : [],
    activeFeatureCounts: eras,
    covered: cells.filter((c) => c.covered).length,
    uncovered: cells.filter((c) => !c.covered).length,
    cells,
  };
}
