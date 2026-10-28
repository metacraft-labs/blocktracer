#!/usr/bin/env node
// The conformance template tests tree shape, copying and hashing. Its explicitly
// labeled placeholders are generated without any recorder or network dependency.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function placeholderFor(transaction) {
  return `example container placeholder for ${transaction}\n`
    + 'A recorder writes its own trace container here. Nothing in the contract reads these bytes: they are copied verbatim and hashed.\n';
}

export function prepareTemplate(dir) {
  const snapshot = JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8'));
  let count = 0;
  for (const row of snapshot.transactions) {
    if (!row.container) continue;
    if (row.container.startsWith('/') || row.container.split('/').includes('..')
        || !row.container.endsWith('.ct')) throw new Error(`invalid template output: ${row.container}`);
    const output = join(dir, row.container);
    const bytes = placeholderFor(row.txHash);
    if (Buffer.byteLength(bytes) !== row.containerBytes) throw new Error(`template byte count differs for ${row.txHash}`);
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, bytes);
    count++;
  }
  return count;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dir = process.argv[2] ?? resolve(dirname(fileURLToPath(import.meta.url)), '../../conformance-kit/template/complete');
  console.log(`conformance template: ${prepareTemplate(dir)} explicit placeholders prepared`);
}
