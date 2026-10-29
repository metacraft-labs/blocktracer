#!/usr/bin/env node
// Inventory validation uses copies of the real committed snapshot manifests.
// No recorder is mocked: producer integration is exercised by prepare-recordings
// and the repository's existing reader, publisher and explorer tests. The
// shipped-engine check is driven with header-only byte strings, because the
// check reads only the container byte and the `meta.dat` header; whether the
// engine really opens a prepared container is `tools/deploy/engine-opens.mjs`.
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, cpSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { ROOT, validateManifest } from './prepare-recordings.mjs';
import { prepareTemplate } from './template-placeholders.mjs';
import { versionsOf, shippedEngine, engineRefusal } from '../chain/lib/container-versions.mjs';

const manifest = JSON.parse(readFileSync(join(ROOT, 'tools/fixtures/recordings.json'), 'utf8'));
const copy = () => structuredClone(manifest);
assert.equal(validateManifest(manifest).length, 55);
const missing = copy();
missing.recordings.pop();
assert.throws(() => validateManifest(missing), /inventory differs/);
const duplicate = copy();
duplicate.recordings.push(duplicate.recordings[0]);
assert.throws(() => validateManifest(duplicate), /duplicate/);
const escaping = copy();
escaping.recordings[0].output = '../outside.ct';
assert.throws(() => validateManifest(escaping), /invalid fixture path/);
const unknown = copy();
unknown.recordings[0].kind = 'download-committed-recording';
assert.throws(() => validateManifest(unknown), /unknown producer/);

// The engine check preparation applies to every prepared container. The subjects
// are header-only byte strings: `versionsOf` reads the container byte and the
// `meta.dat` member's `CTMD` header and nothing else, so these exercise exactly
// what it reads. The sets are the REAL shipped-engine entry, so a container at
// the version the producers write (6) is refused by name against today's engine.
const engine = shippedEngine(ROOT);
const header = (container, metaDat) => Buffer.concat([Buffer.from([0xc0, 0xde, 0x72, 0xac, 0xe2, container]),
  Buffer.alloc(18), Buffer.from('CTMD'), Buffer.from([metaDat & 0xff, metaDat >> 8])]);
const accepted = header(engine.acceptsContainerVersions.at(-1), engine.accepts.at(-1));
assert.deepEqual(versionsOf(accepted), { container: engine.acceptsContainerVersions.at(-1),
  metaDat: engine.accepts.at(-1), profile: 0 });
assert.equal(engineRefusal(versionsOf(accepted), engine), null);
assert.ok(!engine.accepts.includes(6), 'the shipped engine reads meta.dat 6, the version the producers write; then preparation must not regenerate it as 7');
assert.match(engineRefusal(versionsOf(header(6, 6)), engine), /^meta\.dat version 6 is not in \[/);
assert.match(engineRefusal(versionsOf(header(3, engine.accepts.at(-1))), engine), /^container version 3 is not in \[/);
assert.match(engineRefusal(versionsOf(Buffer.from('example container placeholder')), engine),
  /container version unreadable .* and meta\.dat version unreadable/);

const temp = mkdtempSync(join(tmpdir(), 'blocktracer-recording-inventory-'));
try {
  const snapshots = new Set(manifest.recordings.map((row) => row.snapshot).filter(Boolean));
  snapshots.add('fixtures/trace/tour/manifest.json');
  for (const path of snapshots) {
    mkdirSync(dirname(join(temp, path)), { recursive: true });
    cpSync(join(ROOT, path), join(temp, path));
  }
  assert.equal(validateManifest(manifest, temp).length, 55);
  const templateDir = join(temp, 'conformance-kit/template/complete');
  assert.equal(prepareTemplate(templateDir), 3);
  const template = JSON.parse(readFileSync(join(templateDir, 'snapshot.json'), 'utf8'));
  for (const row of template.transactions.filter((row) => row.container)) {
    assert.match(readFileSync(join(templateDir, row.container), 'utf8'), /example container placeholder/);
    assert.equal(readFileSync(join(templateDir, row.container)).length, row.containerBytes);
  }
  const unsafeTemplate = structuredClone(template);
  unsafeTemplate.transactions.find((row) => row.container).container = '../escape.ct';
  writeFileSync(join(templateDir, 'snapshot.json'), JSON.stringify(unsafeTemplate));
  assert.throws(() => prepareTemplate(templateDir), /invalid template output/);
  writeFileSync(join(templateDir, 'snapshot.json'), JSON.stringify(template));
  const shrunk = copy();
  const removed = shrunk.recordings.find((row) => row.kind === 'aztec');
  shrunk.recordings = shrunk.recordings.filter((row) => row.output !== removed.output);
  const snapshot = JSON.parse(readFileSync(join(temp, removed.snapshot), 'utf8'));
  delete snapshot.transactions.find((row) => row.txHash === removed.transaction).container;
  writeFileSync(join(temp, removed.snapshot), JSON.stringify(snapshot));
  assert.throws(() => validateManifest(shrunk, temp), /population changed from baseline/);
  console.log('fixture inventory selftest: original 55, missing, duplicate, unsafe path, unknown producer, mutually shrunk inventories; '
    + `shipped-engine check accepts container ${JSON.stringify(engine.acceptsContainerVersions)} / meta.dat ${JSON.stringify(engine.accepts)} `
    + 'and refuses meta.dat 6, container 3 and an unreadable header by name');
} finally {
  rmSync(temp, { recursive: true, force: true });
}
