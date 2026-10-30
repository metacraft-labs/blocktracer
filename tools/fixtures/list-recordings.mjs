#!/usr/bin/env node
// Enumerate the generated population rather than the intentionally empty Git set.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT, validateManifest } from './prepare-recordings.mjs';
const manifest = JSON.parse(readFileSync(join(ROOT, 'tools/fixtures/recordings.json'), 'utf8'));
validateManifest(manifest);
for (const row of manifest.recordings) {
  if (process.argv.includes('--containers') && row.kind === 'placeholder') continue;
  console.log(row.output);
}
