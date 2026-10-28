#!/usr/bin/env node
// Materialize recordings from their original program or immutable replay inputs.
// All subprocesses are real producers. Failure leaves each previous complete file
// untouched; fingerprints bind cached outputs to their inputs and actual tools.
import {
  existsSync, readFileSync, writeFileSync, readdirSync, mkdirSync, mkdtempSync,
  rmSync, cpSync, renameSync,
} from 'node:fs';
import { dirname, join, resolve, relative, basename } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { placeholderFor } from './template-placeholders.mjs';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const MANIFEST = join(ROOT, 'tools/fixtures/recordings.json');
const STATE = join(ROOT, '.fixture-recordings', 'state.json');
const digest = (data) => createHash('sha256').update(data).digest('hex');
const hashFile = (path) => digest(readFileSync(path));
const json = (path) => JSON.parse(readFileSync(path, 'utf8'));

function filesUnder(path) {
  return readdirSync(path, { withFileTypes: true }).flatMap((entry) => {
    const child = join(path, entry.name);
    return entry.isDirectory() ? filesUnder(child) : [child];
  }).sort();
}

function checkedPath(root, path) {
  if (typeof path !== 'string' || !path || path.startsWith('/')
      || path.split('/').includes('..')) throw new Error(`invalid fixture path: ${path}`);
  return join(root, path);
}

/** Derive the required output population independently from the producer inventory. */
export function expectedOutputs(root = ROOT) {
  const outputs = [];
  for (const base of ['client/fixtures/chain', 'fixtures/chain-artifacts']) {
    for (const entry of readdirSync(join(root, base), { withFileTypes: true })) {
      const dir = `${base}/${entry.name}`;
      if (!entry.isDirectory() || !existsSync(join(root, dir, 'snapshot.json'))) continue;
      for (const row of json(join(root, dir, 'snapshot.json')).transactions) {
        if (row.container) outputs.push(`${dir}/${row.container}`);
      }
    }
  }
  for (const dir of ['client/fixtures/noir-frames', 'conformance-kit/template/complete']) {
    for (const row of json(join(root, dir, 'snapshot.json')).transactions) {
      if (row.container) outputs.push(`${dir}/${row.container}`);
    }
  }
  const tour = json(join(root, 'fixtures/trace/tour/manifest.json'));
  for (const program of tour.programs) {
    outputs.push(`fixtures/trace/tour/${program.container}`);
  }
  outputs.push('fixtures/trace/noir_space_ship/zk_shields.ct');
  return outputs.sort();
}

export function validateManifest(manifest, root = ROOT) {
  if (manifest.format !== 'blocktracer/generated-recordings/v1') throw new Error('unknown fixture manifest format');
  const outputs = manifest.recordings.map((row) => {
    checkedPath(root, row.output);
    if (!['aztec', 'noir', 'placeholder'].includes(row.kind)) {
      throw new Error(`unknown producer for ${row.output}: ${row.kind}`);
    }
    return row.output;
  }).sort();
  if (new Set(outputs).size !== outputs.length) throw new Error('duplicate fixture output');
  const expected = expectedOutputs(root);
  if (JSON.stringify(outputs) !== JSON.stringify(expected)) {
    throw new Error(`fixture inventory differs from the snapshot and tour manifests: missing `
      + expected.filter((p) => !outputs.includes(p)).join(', ') + '; unexpected '
      + outputs.filter((p) => !expected.includes(p)).join(', '));
  }
  if (outputs.length !== manifest.baseline.trackedPaths) {
    throw new Error(`fixture population changed from baseline ${manifest.baseline.commit}: `
      + `${manifest.baseline.trackedPaths} -> ${outputs.length}`);
  }
  return outputs;
}

function run(command, args, cwd, allowed = [0]) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, RAYON_NUM_THREADS: '2', HARDWARE_CONCURRENCY: '2' } });
  if (result.error || !allowed.includes(result.status)) {
    throw new Error(`${command} ${args.join(' ')} failed: `
      + (result.error?.message ?? `exit ${result.status}\n${result.stderr}\n${result.stdout}`));
  }
  return result;
}

function uuidFor(subject) {
  const h = digest(subject);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-7${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

function toolsFromEnv(kinds) {
  const names = [];
  if (kinds.has('noir')) names.push('NARGO', 'CT_COMPACT_CONTAINER');
  if (kinds.has('aztec')) names.push('CT_AZTEC_NODE', 'CT_AZTEC_RUNTIME', 'CT_AZTEC_WRITER_WASM', 'CT_AZTEC_AVM_WASM');
  const tools = {};
  for (const name of names) {
    if (!process.env[name] || !existsSync(process.env[name])) {
      throw new Error(`${name} must name the pinned fixture producer; enter the development shell`);
    }
    tools[name] = resolve(process.env[name]);
  }
  return tools;
}

export function prepareRecordings({ force = false, check = false, producer: selectedProducer = null, log = console.log } = {}) {
  const manifest = json(MANIFEST);
  validateManifest(manifest);
  if (selectedProducer !== null && !['noir', 'aztec', 'placeholder'].includes(selectedProducer)) {
    throw new Error(`unknown selected producer: ${selectedProducer}`);
  }
  const rows = manifest.recordings.filter((row) => selectedProducer === null || row.kind === selectedProducer);
  const tools = toolsFromEnv(new Set(rows.map((row) => row.kind)));
  const runtimeFiles = tools.CT_AZTEC_RUNTIME ? ['replay/src', 'replay/tools', 'ct-host/src'].flatMap((p) =>
    filesUnder(join(tools.CT_AZTEC_RUNTIME, p))) : [];
  const producer = digest(JSON.stringify([
    tools,
    ['node', process.execPath, process.version, hashFile(process.execPath)],
    ...['NARGO', 'CT_AZTEC_NODE', 'CT_AZTEC_WRITER_WASM', 'CT_AZTEC_AVM_WASM', 'CT_COMPACT_CONTAINER'].filter((p) => tools[p]).map((p) => [p, hashFile(tools[p])]),
    ...runtimeFiles.map((p) => [relative(tools.CT_AZTEC_RUNTIME, p), hashFile(p)]),
    ...(tools.CT_AZTEC_RUNTIME ? [hashFile(join(tools.CT_AZTEC_RUNTIME, 'pins.json')),
      hashFile(join(tools.CT_AZTEC_RUNTIME, 'replay/package-lock.json'))] : []),
    hashFile(MANIFEST), hashFile(fileURLToPath(import.meta.url)),
    hashFile(join(ROOT, 'tools/fixtures/template-placeholders.mjs')),
  ]));
  const previous = existsSync(STATE) ? json(STATE) : {};
  const next = selectedProducer ? { ...previous } : {};
  // Keep staging on the output filesystem: /tmp can be a different mount, and
  // installing a complete recording relies on an atomic rename.
  mkdirSync(dirname(STATE), { recursive: true });
  const work = mkdtempSync(join(dirname(STATE), 'recording-'));
  const aztecOutputs = new Map();
  try {
    for (const row of rows) {
      const output = checkedPath(ROOT, row.output);
      let inputs = [];
      if (row.snapshot) inputs.push(checkedPath(ROOT, row.snapshot));
      if (row.kind === 'noir') inputs.push(...filesUnder(checkedPath(ROOT, row.sources)));
      if (row.kind === 'aztec') inputs.push(checkedPath(ROOT, row.input));
      const key = digest(JSON.stringify([producer, row, ...inputs.map((p) => [p.startsWith(ROOT) ? relative(ROOT, p) : p, hashFile(p)])]));
      if (!force && previous[row.output]?.key === key && existsSync(output)
          && previous[row.output].hash === hashFile(output)) {
        next[row.output] = previous[row.output];
        continue;
      }
      if (check) throw new Error(`${row.output} needs recording from its current inputs`);
      const subjectDir = join(work, digest(row.output));
      mkdirSync(subjectDir);
      const staged = join(subjectDir, basename(output));
      if (row.kind === 'placeholder') {
        const tx = basename(output, '.ct');
        writeFileSync(staged, placeholderFor(tx));
      } else if (row.kind === 'noir') {
        const source = join(subjectDir, 'sources');
        cpSync(checkedPath(ROOT, row.sources), source, { recursive: true });
        // Identity follows this actual subject and its producers, independent of
        // workspace roots and whether preparation selected Noir or all kinds.
        const inputDigests = inputs.map((p) => [relative(ROOT, p), hashFile(p)])
          .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
        const recordingId = uuidFor(JSON.stringify([row, inputDigests,
          ['NARGO', hashFile(tools.NARGO)], ['CT_COMPACT_CONTAINER', hashFile(tools.CT_COMPACT_CONTAINER)]]));
        run(tools.NARGO, ['trace', '--out-dir', subjectDir, '--recording-id', recordingId,
          '--recording-workdir', row.recordingWorkdir], source);
        run(tools.CT_COMPACT_CONTAINER, ['--threshold', '1048576', staged], ROOT);
      } else if (row.kind === 'aztec') {
        const captured = json(checkedPath(ROOT, row.input));
        if (captured.provenance.txHash !== row.transaction
            || captured.provenance.rollupVersion !== row.rollupVersion) {
          throw new Error(`captured inputs identify another transaction or deployment for ${row.output}`);
        }
        let report;
        if (aztecOutputs.has(row.input)) {
          const cached = aztecOutputs.get(row.input);
          cpSync(cached.output, staged);
          report = cached.report;
        } else {
          const replay = run(tools.CT_AZTEC_NODE, ['--experimental-wasm-exnref',
            join(tools.CT_AZTEC_RUNTIME, 'replay/tools/replay_settled_transaction.mjs'),
            '--fixture', checkedPath(ROOT, row.input), '--module', tools.CT_AZTEC_AVM_WASM,
            '--ct-writer', tools.CT_AZTEC_WRITER_WASM, '--ct', staged,
            '--compact-threshold', '1048576', '--json'], tools.CT_AZTEC_RUNTIME, [0, 1]);
          try {
            report = JSON.parse(replay.stdout);
          } catch (error) {
            throw new Error(`replay produced invalid JSON for ${row.output} (exit ${replay.status}):\n`
              + `${replay.stderr}\n${replay.stdout}`, { cause: error });
          }
        }
        if (report.txHash !== row.transaction) throw new Error(`replay recorded a different transaction for ${row.output}`);
        const snapshot = json(checkedPath(ROOT, row.snapshot));
        const expected = snapshot.transactions.find((t) => t.txHash === row.transaction);
        const outcome = report.verdict.reproduced ? 'replayed' : 'divergent';
        if (outcome !== expected.outcome) throw new Error(`replay changed the outcome for ${row.output}`);
        for (const [name, value] of Object.entries(expected.recording ?? {})) {
          if (!(name in (report.recording ?? {})) || !isDeepStrictEqual(value, report.recording[name])) {
            throw new Error(`replay changed recording.${name} for ${row.output}: `
              + `${JSON.stringify(value)} -> ${JSON.stringify(report.recording[name])}`);
          }
        }
        aztecOutputs.set(row.input, { output, report });
      }
      if (!existsSync(staged)) throw new Error(`producer wrote no ${row.output}`);
      if (row.snapshot) {
        const expected = json(checkedPath(ROOT, row.snapshot)).transactions.find((t) =>
          `${dirname(row.snapshot)}/${t.container}` === row.output);
        if (!expected) throw new Error(`snapshot does not name ${row.output}`);
        const bytes = readFileSync(staged).length;
        if (bytes !== expected.containerBytes) {
          throw new Error(`${row.output}: generated ${bytes} bytes, snapshot declares ${expected.containerBytes}; `
            + 'measure and update the writer layout and producer provenance explicitly');
        }
      }
      mkdirSync(dirname(output), { recursive: true });
      renameSync(staged, output);
      next[row.output] = { key, hash: hashFile(output) };
      log(`recorded ${row.output}`);
    }
    if (!check) {
      mkdirSync(dirname(STATE), { recursive: true });
      writeFileSync(STATE, JSON.stringify(next, null, 2) + '\n');
    }
    return rows.length;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const at = process.argv.indexOf('--producer');
    const producer = at < 0 ? null : process.argv[at + 1];
    if (at >= 0 && !producer) throw new Error('--producer requires noir, aztec or placeholder');
    const count = prepareRecordings({ force: process.argv.includes('--force'), check: process.argv.includes('--check'), producer });
    console.log(`fixture recordings: ${count} prepared`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
