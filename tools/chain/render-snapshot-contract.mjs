// render-snapshot-contract.mjs — §5.2b's and §5.4's tables, from the census.
//
//   node tools/chain/render-snapshot-contract.mjs
//
// The census (`snapshot-contract.json`) is the machine-readable form of
// `Data-Contract.md` §5, and it is what `snapshot-contract-selftest.mjs` checks the
// reader against. The SPEC still has to read as prose, so its member tables are
// RENDERED from that file rather than typed beside it — one command, pasted into
// §5.2b and §5.4, so the two copies are a transcription with a reproducible source
// rather than two hands writing the same list.
//
// It writes to stdout and touches nothing.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const c = JSON.parse(readFileSync(join(here, 'snapshot-contract.json'), 'utf8'));

const cell = (s) => String(s).replace(/\|/g, '\\|');
const req = (e) => {
  if (!e.required) return 'no';
  if (e.sinceToken) return `on \`${e.sinceToken.replace('blocktracer/chain-snapshot@', '@')}\``;
  if (e.onRows) return `on ${e.onRows}`;
  return 'yes';
};

for (const [id, body] of Object.entries(c.containers)) {
  const members = Object.entries(body.members ?? {});
  if (members.length === 0) continue;
  console.log(`\n**\`${id}\`** — ${body.section}`
    + (body.namedBy ? `, named by \`${body.namedBy}\`` : '')
    + (body.defaultPath ? `, default \`${body.defaultPath}\`` : '')
    + (body.versionToken ? `, token \`${body.versionToken}\`` : '') + '\n');
  console.log('| Member | Required | Safe read | Holds |');
  console.log('| ------ | -------- | --------- | ----- |');
  for (const [m, e] of members) {
    console.log(`| \`${cell(m)}\` | ${req(e)} | ${e.access === 'optional' ? 'yes' : '**no**'}`
      + `${e.enforcedBy ? ` — ${e.enforcedBy}` : ''} | ${cell(e.holds)} |`);
  }
}

console.log('\n\n== RULES ==\n');
console.log('| Rule | Section | Statement |');
console.log('| ---- | ------- | --------- |');
for (const [id, r] of Object.entries(c.rules)) {
  console.log(`| \`${id}\` | ${r.section} | ${cell(r.statement)} |`);
}
