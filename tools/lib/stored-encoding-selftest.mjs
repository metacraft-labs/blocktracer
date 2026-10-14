#!/usr/bin/env node
// Does the stored-encoding answer come from the MANIFEST, and only when there
// is something to say?
//
// Every arm is a synthetic tree, because the question is about what a server
// reads beside a file and not about any particular corpus.

import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { storedEncodingFor, storedEncodingHeader } from './stored-encoding.mjs';

let pass = 0, fail = 0;
const ck = (claim, ok) => {
  if (ok) { pass++; console.log(`  [OK]     ${claim}`); }
  else { fail++; console.log(`  [FAILED] ${claim}`); }
};

const root = mkdtempSync(join(tmpdir(), 'stored-enc-'));
const mk = (name, manifest, file = 'trace.ct') => {
  const d = join(root, name);
  mkdirSync(d, { recursive: true });
  writeFileSync(join(d, file), 'bytes');
  if (manifest !== null) writeFileSync(join(d, 'manifest.json'), JSON.stringify(manifest));
  return join(d, file);
};

console.log('=== stored-encoding: the manifest is the declaration ===\n');

ck('a container whose manifest says `br` is served with that header',
   storedEncodingFor(mk('br', { container: { encoding: 'br' } })) === 'br');

ck('a container whose manifest has NO encoding field is served raw',
   storedEncodingFor(mk('none', { container: { bytes: 5 } })) === '');

// `identity` and absent are one answer. `parseContainerEncoding` says the
// field's PRESENCE is what records that compression happened, so an explicit
// `identity` must not become a header — `Content-Encoding: identity` is legal
// but pointless, and a header nobody meant is a header someone debugs.
ck('an explicit `identity` is not a header either',
   storedEncodingFor(mk('ident', { container: { encoding: 'identity' } })) === '');

ck('an empty-string encoding is not a header',
   storedEncodingFor(mk('empty', { container: { encoding: '' } })) === '');

// THE CONTROL THAT KEEPS THIS CHEAP AND NARROW. Only `trace.ct` is ever
// encoded, so every other path must answer without reading anything — and must
// not pick up a sibling container's manifest.
ck('a NON-container beside an encoded container answers nothing',
   storedEncodingFor(mk('sibling', { container: { encoding: 'br' } }, 'manifest-ish.json')) === '');

ck('a container with NO manifest answers nothing rather than guessing',
   storedEncodingFor(mk('nomanifest', null)) === '');

ck('an unparseable manifest answers nothing rather than throwing',
   (() => {
     const d = join(root, 'broken');
     mkdirSync(d, { recursive: true });
     writeFileSync(join(d, 'trace.ct'), 'bytes');
     writeFileSync(join(d, 'manifest.json'), '{ not json');
     return storedEncodingFor(join(d, 'trace.ct')) === '';
   })());

// The header shape, because a server spreads it and `{}` must be spreadable.
ck('the header helper gives a spreadable object, empty when there is nothing to say',
   JSON.stringify(storedEncodingHeader(mk('h1', { container: { encoding: 'br' } })))
     === '{"Content-Encoding":"br"}'
   && JSON.stringify(storedEncodingHeader(mk('h2', null))) === '{}');

rmSync(root, { recursive: true, force: true });
console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} of ${pass + fail} assertion(s)`);
process.exit(fail === 0 ? 0 : 1);
