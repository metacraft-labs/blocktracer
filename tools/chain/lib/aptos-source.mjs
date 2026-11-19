// aptos-source.mjs — the Aptos source provider: the account's published package source, read
// over REST at the version a transaction ran on, and proved against the module bytes the
// chain held by compiling it and comparing bytes.
//
// ── WHAT IT ANSWERS ───────────────────────────────────────────────────────────────────
//
// Source-Resolution.md §3 names Aptos's provider "account module source via the REST API",
// and §4 says how Move source is validated: "compare published module bytes with the compiled
// source's module bytes". Aptos publishes a package's source on chain, beside its bytecode,
// in the `0x1::code::PackageRegistry` resource at the publishing account: per package its
// manifest, `upgrade_number`, `source_digest`, its dependencies, and per module the
// gzip-compressed source (empty when the package was published without it) and a source map
// (empty unless published with `--included-artifacts all`).
//
// For every module a recorded transaction entered, `resolveSources` reads the registry of
// the module's account AT V−1 — the state the transaction ran on, so a package upgraded
// since resolves to the version that ran — finds the package holding the module, collects
// its dependency closure the same way, writes the published source of every package in the
// closure into a build workspace, compiles the package with the Aptos CLI, and compares the
// module bytes the compiler wrote with the bytes the chain held at V−1 (the `.mv` the
// recorder fetched into the replay directory). EQUAL BYTES ARE THE ONLY WAY A MODULE IS
// `verified`. Anything else leaves it on its disassembly, with the reason recorded.
//
// ── WHAT IS CHANGED BEFORE COMPILING, AND WHY IT CANNOT CHANGE A VERDICT ──────────────
//
// The published source of a package is its `sources/*.move` and NOT its `*.spec.move`
// files, so a specification that names a ghost variable or a `spec fun` declared in one of
// those does not type-check. The compiler is asked first with the source as published; the
// specification syntax it rejects — and only that — is blanked to spaces, byte for byte, and
// it is asked again, to a fixed point. A top-level `spec` item is blanked whole; an inline
// `spec { … }` keeps its braces, because the compiler emits a `nop` for it. Byte offsets and
// line breaks are unchanged, so the compiler's source map indexes the published text
// exactly. Specifications generate no code, and if blanking one changed the code anyway the
// bytes would differ and the module would not verify: the comparison is what decides.
//
// The compiler is the CLI handed in (the fork's, on aptos-node v1.49.8), at the compiler,
// language and bytecode versions the module's own `compilation_metadata` names. Which
// optimisation experiments a package was built with is not recorded on chain, so two build
// profiles are tried in order — the framework release's (`aptos-move/framework/src/aptos.rs`)
// and the CLI's default — and the first whose bytes are equal is recorded. Trying a second
// profile does not weaken the check: a profile is accepted only by equality.
//
// ── WHAT A VERIFIED MODULE GETS ───────────────────────────────────────────────────────
//
// In the replay directory, beside `bytecode/<m>.mv` and its disassembly:
//
//   0x<address>/source/<m>.move   the module's published source, verbatim
//   0x<address>/source/<m>.json   the compiler's source map for those exact bytes
//                                 (`codetracer/aptos-source-map@1`), which the recorder
//                                 positions steps and names locals with
//
// plus the source of every other module whose code the compiler inlined into it (the
// framework is built with cross-module inlining, so an instruction's position can be in
// another module's file). And `sources.json` names every module the trace entered with its
// outcome. The producer turns that report into the row's `artifacts` and source bundles.

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { gunzipSync } from 'node:zlib';

const run = promisify(execFile);

/** The report `resolveSources` writes beside the replay's modules. */
export const SOURCE_RESOLUTION_FORMAT = 'blocktracer/aptos-source-resolution@1';
/** The source-map document the recorder reads (`codetracer-move-recorder`). */
export const SOURCE_MAP_FORMAT = 'codetracer/aptos-source-map@1';
/** The resource a package's metadata and source are published in. */
export const PACKAGE_REGISTRY = '0x1::code::PackageRegistry';

/**
 * Every outcome a module can have, closed. Only `verified` shows source; each of the others
 * is a reason the module stays on its disassembly.
 */
export const OUTCOMES = Object.freeze({
  verified: 'the published source compiles to the bytes the chain held',
  'no-registry': 'the account holds no package registry at that version',
  'no-package': 'no package in the account\'s registry names the module',
  'source-not-published': 'the package was published without source',
  'dependency-source-not-published': 'a package it depends on was published without source',
  'compile-failed': 'the published source does not compile',
  'bytecode-mismatch': 'the published source compiles to bytes other than the chain\'s',
});

/**
 * The build profiles tried, in order. `experiments` are the Move compiler's (`MVC_EXP`).
 * The first is the framework release's, from aptos-core `aptos-move/framework/src/aptos.rs`
 * (`create_release_options`); the second is what `aptos move compile` does by default.
 */
export const BUILD_PROFILES = Object.freeze([
  Object.freeze({ name: 'framework-release',
                  experiments: Object.freeze(['optimize-extra=on',
                                              'extended-framework-optimizations=on']) }),
  Object.freeze({ name: 'cli-default', experiments: Object.freeze([]) }),
]);

const sha256 = (b) => createHash('sha256').update(b).digest('hex');
export const normalizeAddress = (a) => {
  const hex = String(a).replace(/^0[xX]/, '').toLowerCase();
  if (!/^[0-9a-f]{1,64}$/.test(hex)) throw new Error(`not an account address: '${a}'`);
  return hex.padStart(64, '0');
};
const shortAddress = (hex64) => `0x${hex64.replace(/^0+(?=.)/, '')}`;

// ── BCS ──────────────────────────────────────────────────────────────────────────────

/** A minimal BCS reader: exactly what the two documents below are made of. */
export class Bcs {
  constructor(buf) { this.b = buf; this.o = 0; }
  need(n) {
    if (this.o + n > this.b.length) throw new Error(`BCS: ${n} byte(s) past the end at ${this.o}`);
  }
  u8() { this.need(1); return this.b[this.o++]; }
  u16() { this.need(2); const v = this.b.readUInt16LE(this.o); this.o += 2; return v; }
  u32() { this.need(4); const v = this.b.readUInt32LE(this.o); this.o += 4; return v; }
  u64() { this.need(8); const v = this.b.readBigUInt64LE(this.o); this.o += 8; return v; }
  uleb() {
    let v = 0;
    for (let shift = 0; shift <= 28; shift += 7) {
      const x = this.u8();
      v += (x & 0x7f) * 2 ** shift;
      if ((x & 0x80) === 0) return v;
    }
    throw new Error('BCS: a length longer than 32 bits');
  }
  bytes(n) { this.need(n); const v = this.b.subarray(this.o, this.o + n); this.o += n; return v; }
  vecBytes() { return this.bytes(this.uleb()); }
  str() { return this.vecBytes().toString('utf8'); }
  bool() {
    const v = this.u8();
    if (v > 1) throw new Error(`BCS: bool ${v}`);
    return v === 1;
  }
  vec(f) {
    const n = this.uleb();
    const out = [];
    for (let i = 0; i < n; i++) out.push(f(this));
    return out;
  }
  option(f) {
    const t = this.u8();
    if (t > 1) throw new Error(`BCS: option tag ${t}`);
    return t ? f(this) : null;
  }
  end() {
    if (this.o !== this.b.length) throw new Error(`BCS: ${this.b.length - this.o} trailing byte(s)`);
  }
}

/**
 * `0x1::code::PackageRegistry`, as the REST API answers it in BCS
 * (`Accept: application/x-bcs`). Move's `Option<T>` is a struct holding a vector, so it is
 * a length-prefixed vector of at most one element on the wire.
 */
export function decodePackageRegistry(buf) {
  const r = new Bcs(buf);
  const moveOption = (x, f) => {
    const v = x.vec(f);
    if (v.length > 1) throw new Error('BCS: a Move Option holding more than one value');
    return v[0] ?? null;
  };
  const any = (x) => ({ typeName: x.str(), data: x.vecBytes() });
  const packages = r.vec((x) => ({
    name: x.str(),
    upgradePolicy: x.u8(),
    upgradeNumber: x.u64().toString(),
    sourceDigest: x.str(),
    manifest: x.vecBytes(),
    modules: x.vec((y) => ({
      name: y.str(), source: y.vecBytes(), sourceMap: y.vecBytes(),
      extension: moveOption(y, any),
    })),
    deps: x.vec((y) => ({ account: y.bytes(32).toString('hex'), packageName: y.str() })),
    extension: moveOption(x, any),
  }));
  r.end();
  return { packages };
}

/**
 * move-bytecode-source-map's `SourceMap` (`.mvsm`), as aptos-core v1.49.8 writes it: BCS of
 * `{definition_location, module_name_opt, struct_map, function_map, constant_map}`, where a
 * `Loc` is `{file_hash: [u8; 32], start: u32, end: u32}` — byte offsets into the file whose
 * SHA-256 is `file_hash`.
 */
export function decodeSourceMap(buf) {
  const r = new Bcs(buf);
  const loc = (x) => ({ fileHash: x.bytes(32).toString('hex'), start: x.u32(), end: x.u32() });
  const named = (x) => [x.str(), loc(x)];
  const definitionLocation = loc(r);
  const moduleName = r.option((x) => [x.bytes(32).toString('hex'), x.str()]);
  const structMap = r.vec((x) => [x.u16(), {
    definitionLocation: loc(x), typeParameters: x.vec(named), fields: x.vec((y) => y.vec(loc)),
  }]);
  const functionMap = r.vec((x) => [x.u16(), {
    definitionLocation: loc(x),
    typeParameters: x.vec(named),
    parameters: x.vec(named),
    locals: x.vec(named),
    nops: x.vec((y) => [y.str(), y.u16()]),
    codeMap: x.vec((y) => [y.u16(), loc(y)]),
    isNative: x.bool(),
  }]);
  const constantMap = r.vec((x) => [x.str(), x.u16()]);
  r.end();
  return { definitionLocation, moduleName, structMap, functionMap, constantMap };
}

/**
 * The versions a module says it was compiled with: the bytecode version from its header,
 * and the compiler and language versions from its `compilation_metadata` entry
 * (`{unstable: bool, compiler_version: String, language_version: String}`, BCS). Null for
 * a member the module does not carry.
 */
export function compilationMetadata(mv) {
  const out = { bytecodeVersion: null, compilerVersion: null, languageVersion: null };
  if (mv.length < 8 || mv.readUInt32BE(0) !== 0xa11ceb0b) return out;
  // The version word carries the Aptos binary-format flag (0x0A000000) in its top byte.
  out.bytecodeVersion = mv.readUInt32LE(4) & 0xffff;
  const key = Buffer.from('compilation_metadata');
  const at = mv.indexOf(Buffer.concat([Buffer.from([key.length]), key]));
  if (at < 0) return out;
  try {
    const r = new Bcs(mv.subarray(at + 1 + key.length));
    const value = new Bcs(r.vecBytes());
    value.bool();
    out.compilerVersion = value.str();
    out.languageVersion = value.str();
    value.end();
  } catch { /* an entry this reader cannot read names nothing */ }
  return out;
}

// ── SPECIFICATIONS ───────────────────────────────────────────────────────────────────

/**
 * Every `spec` construct of a Move source, as byte ranges: `{start, end, kind}` where
 * `kind` is `item` (a top-level `spec …` item, with any `proof { … }` trailer) or `inline`
 * (a `spec { … }` block inside a function, `start`/`end` spanning its interior only).
 * Comments, byte strings and hex strings are skipped as tokens, so a brace inside one is
 * not counted.
 */
export function specRegions(text) {
  const s = Buffer.isBuffer(text) ? text : Buffer.from(text, 'utf8');
  const n = s.length;
  const isId = (c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    || c === 95;
  const skipTrivia = (j) => {
    for (;;) {
      if (j < n && (s[j] === 32 || s[j] === 9 || s[j] === 10 || s[j] === 13)) { j++; continue; }
      if (s[j] === 47 && s[j + 1] === 47) { while (j < n && s[j] !== 10) j++; continue; }
      if (s[j] === 47 && s[j + 1] === 42) {
        j += 2;
        while (j < n && !(s[j] === 42 && s[j + 1] === 47)) j++;
        j += 2;
        continue;
      }
      return j;
    }
  };
  const tokenEnd = (j) => {
    if ((s[j] === 98 || s[j] === 120) && s[j + 1] === 34) {      // b"…" and x"…"
      j += 2;
      while (j < n && s[j] !== 34) { if (s[j] === 92) j++; j++; }
      return j + 1;
    }
    if (isId(s[j])) { while (j < n && isId(s[j])) j++; return j; }
    return j + 1;
  };
  const word = (a, b) => s.subarray(a, b).toString('latin1');
  // The end of the first balanced `{ … }` from `k`, or of a `;` met before any `{` when
  // `semi` (a `spec native fun …;` has no body).
  const blockEnd = (k, semi) => {
    let depth = 0;
    while (k < n) {
      const t = skipTrivia(k);
      if (t >= n) break;
      const te = tokenEnd(t);
      if (te === t + 1 && s[t] === 123) depth++;
      else if (te === t + 1 && s[t] === 125) { if (--depth === 0) return te; }
      else if (semi && depth === 0 && te === t + 1 && s[t] === 59) return te;
      k = te;
    }
    throw new Error(`an unterminated spec block at byte ${k}`);
  };
  const regions = [];
  let i = 0;
  while (i < n) {
    const j = skipTrivia(i);
    if (j >= n) break;
    const e = tokenEnd(j);
    if (word(j, e) !== 'spec') { i = e; continue; }
    const b = skipTrivia(e);
    if (s[b] === 123) {
      const end = blockEnd(b, false);
      regions.push({ start: b + 1, end: end - 1, kind: 'inline' });
      i = end;
      continue;
    }
    let end = blockEnd(e, true);
    const t = skipTrivia(end);
    if (t < n && word(t, tokenEnd(t)) === 'proof') end = blockEnd(tokenEnd(t), false);
    regions.push({ start: j, end, kind: 'item' });
    i = end;
  }
  return regions;
}

/** `buf` with bytes [start, end) turned to spaces, line breaks kept. */
export function blankRange(buf, start, end) {
  const out = Buffer.from(buf);
  for (let k = start; k < end; k++) if (out[k] !== 10 && out[k] !== 13) out[k] = 32;
  return out;
}

/** The tokens of `s[from, to)`, comments and whitespace dropped: `{start, end, text}`. */
export function moveTokens(s, from, to) {
  const isId = (c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    || c === 95;
  const out = [];
  let j = from;
  while (j < to) {
    const c = s[j];
    if (c === 32 || c === 9 || c === 10 || c === 13) { j++; continue; }
    if (c === 47 && s[j + 1] === 47) { while (j < to && s[j] !== 10) j++; continue; }
    if (c === 47 && s[j + 1] === 42) {
      j += 2;
      while (j < to && !(s[j] === 42 && s[j + 1] === 47)) j++;
      j += 2;
      continue;
    }
    let e = j + 1;
    if ((c === 98 || c === 120) && s[j + 1] === 34) {
      e = j + 2;
      while (e < to && s[e] !== 34) { if (s[e] === 92) e++; e++; }
      e++;
    } else if (isId(c)) {
      while (e < to && isId(s[e])) e++;
    } else if ((c === 58 && s[j + 1] === 58) || (c === 61 && s[j + 1] === 61)
               || (c === 38 && s[j + 1] === 38) || (c === 46 && s[j + 1] === 46)) {
      e = j + 2;                                                  // :: == && ..
    }
    out.push({ start: j, end: e, text: s.subarray(j, e).toString('latin1') });
    j = e;
  }
  return out;
}

/** The statements of an inline spec block's interior, split at its top-level `;`. */
export function inlineSpecStatements(s, region) {
  const toks = moveTokens(s, region.start, region.end);
  const out = [];
  let depth = 0;
  let first = null;
  for (const t of toks) {
    if (first === null) first = t.start;
    if ('([{'.includes(t.text)) depth++;
    else if (')]}'.includes(t.text)) depth--;
    else if (t.text === ';' && depth === 0) { out.push({ start: first, end: t.end }); first = null; }
  }
  if (first !== null) out.push({ start: first, end: region.end });
  return out;
}

const SPEC_WORDS = new Set(['true', 'false', 'forall', 'exists', 'in', 'where', 'old', 'global',
  'result', 'let', 'if', 'else', 'update', 'invariant', 'assert', 'assume', 'decreases',
  'modifies', 'emits', 'to', 'Self', 'choose', 'min', 'post', 'pack', 'unpack']);

/**
 * The LOCAL VARIABLES a spec statement names, in order, once each: identifiers that are not
 * a field (`.x`), a module or a member of one (`m::`, `::f`), a call (`f(`, `f<`), a
 * constant (an upper-case first letter), a spec keyword, or a name the statement binds
 * itself (`forall x in …`, `forall x: T`, `let x = …`).
 */
export function specStatementLocals(s, stmt) {
  const toks = moveTokens(s, stmt.start, stmt.end);
  const bound = new Set();
  for (let i = 0; i < toks.length; i++) {
    const prev = toks[i - 1]?.text;
    const next = toks[i + 1]?.text;
    if (next === 'in' || (next === ':' && ['forall', 'exists', ','].includes(prev))
        || (prev === 'let' && next === '=')) {
      bound.add(toks[i].text);
    }
  }
  const out = [];
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i].text;
    const prev = toks[i - 1]?.text;
    const next = toks[i + 1]?.text;
    if (!/^[a-z_][A-Za-z0-9_]*$/.test(t) || SPEC_WORDS.has(t) || bound.has(t)) continue;
    if (prev === '.' || prev === '::' || next === '::' || next === '(' || next === '<') continue;
    if (i === 0) continue;                                      // the statement's keyword
    if (!out.includes(t)) out.push(t);
  }
  return out;
}

/**
 * `stmt` rewritten in place, at its own length and with its line breaks where they were,
 * into `<keyword> x==x&&y==y…;` over the locals it names — so the variables a specification
 * keeps alive stay alive, which decides how the compiler allocates local slots — or null
 * when that does not fit. The result is only ever accepted by a byte comparison.
 */
export function rewriteSpecStatement(s, stmt) {
  const toks = moveTokens(s, stmt.start, stmt.end);
  if (toks.length === 0) return null;
  const keyword = toks[0].text;
  if (!['invariant', 'assert', 'assume'].includes(keyword)) return null;
  const locals = specStatementLocals(s, stmt);
  const pieces = [keyword, ...(locals.length ? locals.flatMap((x, i) => [...(i ? ['&&'] : []),
    `${x}==${x}`]) : ['true']), ';'];
  // The line segments of the statement, so no piece straddles a line break.
  const segs = [];
  let a = stmt.start;
  for (let k = stmt.start; k <= stmt.end; k++) {
    if (k === stmt.end || s[k] === 10 || s[k] === 13) { if (k > a) segs.push([a, k]); a = k + 1; }
  }
  const out = blankRange(s, stmt.start, stmt.end);
  let p = 0;
  for (const [x, y] of segs) {
    let k = x;
    while (p < pieces.length) {
      const sep = p > 0 && p !== pieces.length - 1 && k > x ? 1 : 0;
      const w = pieces[p];
      if (k + sep + w.length > y) break;
      k += sep;
      out.write(w, k, 'latin1');
      k += w.length;
      p++;
    }
  }
  return p === pieces.length ? out : null;
}

/** The `file:line:col` of every ERROR (not warning) the Move compiler printed. */
export function compilerErrorLocations(output) {
  const plain = String(output).replace(/\x1b\[[0-9;]*m/g, '');
  const out = [];
  let inError = false;
  for (const line of plain.split('\n')) {
    if (/^error(\[[^\]]*\])?:/.test(line)) { inError = true; continue; }
    if (/^(warning|note|bug)(\[[^\]]*\])?:/.test(line)) { inError = false; continue; }
    const m = inError && line.match(/┌─ (.+):(\d+):(\d+)\s*$/);
    if (m) {
      out.push({ file: m[1], line: Number(m[2]), column: Number(m[3]) });
      inError = false;
    }
  }
  return out;
}

const byteOffsetOf = (buf, line, column) => {
  let l = 1;
  let k = 0;
  while (l < line && k < buf.length) { if (buf[k] === 10) l++; k++; }
  return k + column - 1;
};

// ── REST ─────────────────────────────────────────────────────────────────────────────

/** An account's package registry at `ledgerVersion`, or null where the account holds none. */
export async function packageRegistryAt(base, address, ledgerVersion,
                                        { fetchImpl = fetch, retries = 6 } = {}) {
  const url = `${base}/v1/accounts/${shortAddress(normalizeAddress(address))}/resource/`
    + `${PACKAGE_REGISTRY}?ledger_version=${ledgerVersion}`;
  for (let attempt = 0; ; attempt++) {
    const res = await fetchImpl(url, { headers: { accept: 'application/x-bcs' } });
    const body = Buffer.from(await res.arrayBuffer());
    if (res.status === 200) return decodePackageRegistry(body);
    if (res.status === 404) return null;
    if ((res.status === 429 || res.status >= 500) && res.status !== 599 && attempt < retries) {
      await new Promise((ok) => setTimeout(ok, res.status === 429 ? 30_000 : 3_000));
      continue;
    }
    throw new Error(`GET ${url} answered ${res.status}: ${body.toString('utf8').slice(0, 300)}`);
  }
}

// ── THE RESOLVER ─────────────────────────────────────────────────────────────────────

/** The `[dependencies]` of a published manifest, re-pointed at the workspace's directories. */
function workspaceManifest(manifest, accountHex, depDirs) {
  const lines = manifest.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let section = '';
  for (const line of lines) {
    const header = line.match(/^\s*\[([^\]]+)\]\s*(#.*)?$/);
    if (header) {
      section = header[1].trim();
      if (section === 'dependencies') continue;
      out.push(line);
      continue;
    }
    if (section === 'dependencies') continue;
    // A placeholder named address is assigned at publish time; the account the package was
    // published at is the usual assignment, and a wrong guess cannot verify.
    if (section === 'addresses' && /=\s*"_"/.test(line)) {
      out.push(line.replace(/"_"/, `"${shortAddress(accountHex)}"`));
      continue;
    }
    out.push(line);
  }
  out.push('', '[dependencies]');
  for (const [name, dir] of depDirs) out.push(`${JSON.stringify(name)} = { local = "../${dir}" }`);
  return `${out.join('\n')}\n`;
}

/**
 * Resolve published source for every module under `replayDir` (`0x<addr>/bytecode/*.mv`),
 * the modules a transaction at `version` entered, and write what verifies beside them.
 * Returns the report it writes to `<replayDir>/sources.json`.
 *
 *   base     the REST base (without `/v1`) — the node, or a transcript serving it
 *   aptos    the Aptos CLI that compiles
 *   work     a scratch directory for build workspaces; reused by identity across calls
 *   cache    a Map shared across calls in one run (registries and builds)
 */
export async function resolveSources({ replayDir, version, base, aptos, work, log = () => {},
                                       cache = new Map(), fetchImpl = fetch,
                                       timeoutMs = 900_000 }) {
  const stateVersion = (BigInt(version) - 1n).toString();
  const entered = [];
  for (const d of readdirSync(replayDir).sort()) {
    const bytecode = join(replayDir, d, 'bytecode');
    if (!d.startsWith('0x') || !existsSync(bytecode)) continue;
    for (const f of readdirSync(bytecode).sort()) {
      if (!f.endsWith('.mv')) continue;
      entered.push({ dir: d, address: normalizeAddress(d), module: f.slice(0, -3),
                     mv: readFileSync(join(bytecode, f)) });
    }
  }

  const registryOf = async (account) => {
    const key = `registry:${account}@${stateVersion}`;
    if (!cache.has(key)) {
      cache.set(key, await packageRegistryAt(base, account, stateVersion, { fetchImpl }));
    }
    return cache.get(key);
  };

  // The package closure of `pkg` at `account`, in dependency order, or the reason there is
  // none. Every package in it carries a source for every module, or it cannot be compiled.
  const closureOf = async (account, pkg) => {
    const seen = new Map();
    const visit = async (acct, p) => {
      const id = `${acct}::${p.name}`;
      if (seen.has(id)) return null;
      seen.set(id, null);
      for (const dep of p.deps) {
        const reg = await registryOf(dep.account);
        const q = reg?.packages.find((x) => x.name === dep.packageName);
        if (!q) return `its dependency ${shortAddress(dep.account)}::${dep.packageName} is in no registry`;
        const why = await visit(dep.account, q);
        if (why) return why;
      }
      seen.set(id, { account: acct, pkg: p });
      return null;
    };
    const why = await visit(account, pkg);
    if (why) return { why };
    const order = [...seen.values()];
    for (const { account: a, pkg: p } of order) {
      const missing = p.modules.filter((m) => m.source.length === 0).map((m) => m.name);
      if (missing.length > 0) {
        return { why: `${shortAddress(a)}::${p.name} was published without the source of `
          + `${missing.length} of its ${p.modules.length} module(s)`, outcome:
          a === account && p === pkg ? 'source-not-published' : 'dependency-source-not-published' };
      }
    }
    return { order };
  };

  const report = [];
  const verdict = (m, outcome, extra) => {
    report.push({ address: `0x${m.address}`, module: m.module, codeHash: `0x${sha256(m.mv)}`,
                  outcome, ...extra });
  };
  const builds = [];
  for (const m of entered) {
    const reg = await registryOf(m.address);
    if (!reg) { verdict(m, 'no-registry', { reason: OUTCOMES['no-registry'] }); continue; }
    const pkg = reg.packages.find((p) => p.modules.some((x) => x.name === m.module));
    if (!pkg) { verdict(m, 'no-package', { reason: OUTCOMES['no-package'] }); continue; }
    const meta = { package: pkg.name, upgradeNumber: pkg.upgradeNumber,
                   sourceDigest: pkg.sourceDigest };
    if (pkg.modules.find((x) => x.name === m.module).source.length === 0) {
      verdict(m, 'source-not-published', { ...meta, reason: `${pkg.name} (upgrade `
        + `${pkg.upgradeNumber}) was published without source` });
      continue;
    }
    const closure = await closureOf(m.address, pkg);
    if (!closure.order) {
      verdict(m, closure.outcome ?? 'dependency-source-not-published', { ...meta,
        reason: closure.why });
      continue;
    }
    let b = builds.find((x) => x.account === m.address && x.pkg === pkg);
    if (!b) {
      b = { account: m.address, pkg, closure: closure.order, modules: [] };
      builds.push(b);
    }
    b.modules.push({ m, meta });
  }

  for (const b of builds) {
    const outcome = await buildAndCompare({ b, work, aptos, log, cache, timeoutMs });
    for (const { m, meta } of b.modules) {
      const r = outcome.modules.get(m.module);
      if (!r.verified) {
        verdict(m, r.outcome, { ...meta, reason: r.reason });
        continue;
      }
      const files = writeVerified({ replayDir, m, r, build: outcome });
      verdict(m, 'verified', { ...meta, reason: OUTCOMES.verified, build: r.build,
                               sourcePath: files.own, sourceMapPath: files.map,
                               files: files.all });
    }
  }
  report.sort((x, y) => (x.address + x.module < y.address + y.module ? -1 : 1));
  const doc = { format: SOURCE_RESOLUTION_FORMAT, ledgerVersion: stateVersion,
                provider: `${PACKAGE_REGISTRY} over REST at ledger version ${stateVersion}`,
                modules: report };
  writeFileSync(join(replayDir, 'sources.json'), `${JSON.stringify(doc, null, 1)}\n`);
  return doc;
}

/**
 * Lay out one package's closure, compile it (blanking the specification syntax the compiler
 * rejects, to a fixed point), and compare each entered module's bytes under each profile.
 * Builds are cached by the closure's content, so one run compiles a package once.
 */
async function buildAndCompare({ b, work, aptos, log, cache, timeoutMs }) {
  const identity = sha256(JSON.stringify(b.closure.map(({ account, pkg }) => [
    account, pkg.name, pkg.upgradeNumber, sha256(pkg.manifest),
    pkg.modules.map((x) => [x.name, sha256(x.source)])])));
  const want = b.modules.map(({ m }) => [m.module, sha256(m.mv)]);
  const cacheKey = `build:${identity}:${JSON.stringify(want)}`;
  if (cache.has(cacheKey)) return cache.get(cacheKey);

  const root = resolve(work, identity.slice(0, 16));
  rmSync(root, { recursive: true, force: true });
  mkdirSync(join(root, 'home'), { recursive: true });
  const dirOf = (account, name) => `${shortAddress(account)}-${name}`;
  // published text and the text compiled, per file, keyed by path in the workspace
  const files = new Map();
  for (const { account, pkg } of b.closure) {
    const dir = join(root, dirOf(account, pkg.name));
    mkdirSync(join(dir, 'sources'), { recursive: true });
    const deps = pkg.deps.map((d) => {
      const q = b.closure.find((x) => x.account === d.account && x.pkg.name === d.packageName);
      return [d.packageName, dirOf(q.account, q.pkg.name)];
    });
    writeFileSync(join(dir, 'Move.toml'),
                  workspaceManifest(gunzipSync(pkg.manifest).toString('utf8'), account, deps));
    for (const mod of pkg.modules) {
      const text = gunzipSync(mod.source);
      const path = join(dir, 'sources', `${mod.name}.move`);
      writeFileSync(path, text);
      files.set(path, { account, module: mod.name, published: text, compiled: text });
    }
  }

  const rootDir = join(root, dirOf(b.account, b.pkg.name));
  const versions = compilationMetadata(b.modules[0].m.mv);
  let attempt = 0;
  const compile = async (profile) => {
    const out = join(root, `build-${profile.name}`);
    const logPath = join(root, `compile-${String(++attempt).padStart(2, '0')}-${profile.name}.log`);
    rmSync(out, { recursive: true, force: true });
    const args = ['move', 'compile', '--package-dir', rootDir, '--output-dir', out,
                  '--skip-fetch-latest-git-deps'];
    if (versions.compilerVersion) args.push('--compiler-version', versions.compilerVersion);
    if (versions.languageVersion) args.push('--language-version', versions.languageVersion);
    if (versions.bytecodeVersion) args.push('--bytecode-version', String(versions.bytecodeVersion));
    const env = { ...process.env, HOME: join(root, 'home'), MVC_EXP: profile.experiments.join(','),
                  NO_COLOR: '1' };
    try {
      const { stdout, stderr } = await run(aptos, args, { cwd: root, env, maxBuffer: 1 << 28,
                                                          timeout: timeoutMs });
      writeFileSync(logPath, `${stdout}\n${stderr}`);
      return { ok: true, out };
    } catch (e) {
      const output = `${e.stdout ?? ''}\n${e.stderr ?? ''}`;
      writeFileSync(logPath, output);
      return { ok: false, out, output };
    }
  };

  // THE FIXED POINT: compile as published; change what the compiler rejects; again. Each
  // rejected construct escalates one step per round it is still rejected: an inline
  // statement is first rewritten over the locals it names, then blanked, then its whole
  // block is; a top-level item is blanked whole at once.
  const blanked = [];
  const level = new Map();
  let first = await compile(BUILD_PROFILES[0]);
  for (let round = 0; !first.ok && round < 32; round++) {
    const errs = compilerErrorLocations(first.output);
    let progressed = false;
    const touched = new Set();
    for (const e of errs) {
      const path = resolve(root, e.file);
      const f = files.get(path);
      if (!f) continue;
      const at = byteOffsetOf(f.compiled, e.line, e.column);
      const region = specRegions(f.compiled).find((r) => at >= r.start && at < r.end);
      if (!region) continue;
      const stmt = region.kind === 'inline'
        ? inlineSpecStatements(f.compiled, region).find((x) => at >= x.start && at < x.end)
        : null;
      const key = `${path}:${stmt ? stmt.start : region.start}`;
      if (touched.has(key)) continue;
      touched.add(key);
      const step = (level.get(key) ?? 0) + 1;
      level.set(key, step);
      let next = null;
      let how;
      if (stmt && step === 1) { next = rewriteSpecStatement(f.compiled, stmt); how = 'rewritten'; }
      if (stmt && !next && step <= 2) {
        next = blankRange(f.compiled, stmt.start, stmt.end);
        how = 'statement blanked';
      }
      if (!next) { next = blankRange(f.compiled, region.start, region.end); how = `${region.kind} blanked`; }
      if (next.equals(f.compiled)) continue;
      f.compiled = next;
      writeFileSync(path, f.compiled);
      blanked.push({ file: `${shortAddress(f.account)}::${f.module}`, line: e.line, how });
      progressed = true;
    }
    if (!progressed) break;
    first = await compile(BUILD_PROFILES[0]);
  }
  if (blanked.length > 0) {
    const n = (how) => blanked.filter((x) => x.how === how).length;
    log(`${shortAddress(b.account)}::${b.pkg.name}: ${blanked.length} specification construct(s) `
      + 'name declarations of the unpublished .spec.move files: '
      + `${n('rewritten')} statement(s) rewritten over their locals, `
      + `${n('statement blanked')} statement(s), ${n('inline blanked')} inline block(s) and `
      + `${n('item blanked')} item(s) blanked`);
  }

  const result = { modules: new Map(), files, root, blanked };
  if (!first.ok) {
    const tail = first.output.replace(/\x1b\[[0-9;]*m/g, '').trim().split('\n').slice(-6)
      .join(' ').slice(0, 600);
    for (const { m } of b.modules) {
      result.modules.set(m.module, { verified: false, outcome: 'compile-failed',
        reason: `the published source of ${b.pkg.name} does not compile with ${aptos.split('/')
          .pop()}: ${tail}` });
    }
    cache.set(cacheKey, result);
    return result;
  }
  const builds = [{ profile: BUILD_PROFILES[0], out: first.out }];
  // `--output-dir D` writes `D/build/<package>/…`.
  const pkgOut = (out) => join(out, 'build', b.pkg.name);
  const pending = new Set(b.modules.map(({ m }) => m.module));
  const sizes = new Map();
  for (let p = 0; p < BUILD_PROFILES.length && pending.size > 0; p++) {
    let built = builds[p];
    if (!built) {
      const c = await compile(BUILD_PROFILES[p]);
      if (!c.ok) continue;
      built = { profile: BUILD_PROFILES[p], out: c.out };
      builds.push(built);
    }
    for (const { m } of b.modules) {
      if (!pending.has(m.module)) continue;
      const mv = join(pkgOut(built.out), 'bytecode_modules', `${m.module}.mv`);
      if (!existsSync(mv)) continue;
      const ours = readFileSync(mv);
      sizes.set(`${m.module}:${built.profile.name}`, ours.length);
      if (!ours.equals(m.mv)) continue;
      pending.delete(m.module);
      result.modules.set(m.module, {
        verified: true,
        sourceMap: decodeSourceMap(readFileSync(join(pkgOut(built.out), 'source_maps',
                                                     `${m.module}.mvsm`))),
        build: { profile: built.profile.name, experiments: [...built.profile.experiments],
                 compilerVersion: versions.compilerVersion,
                 languageVersion: versions.languageVersion,
                 bytecodeVersion: versions.bytecodeVersion,
                 compiler: aptos.split('/').pop(),
                 specificationsChanged: blanked.length },
      });
    }
  }
  for (const name of pending) {
    const m = b.modules.find((x) => x.m.module === name).m;
    const tried = BUILD_PROFILES.map((p) => `${p.name}: ${sizes.has(`${name}:${p.name}`)
      ? `${sizes.get(`${name}:${p.name}`)} bytes` : 'not built'}`).join(', ');
    result.modules.set(name, { verified: false, outcome: 'bytecode-mismatch',
      reason: `the published source of ${b.pkg.name} compiles, and no build profile `
        + `reproduces the ${m.mv.length} bytes the chain held (${tried})` });
  }
  cache.set(cacheKey, result);
  return result;
}

/**
 * Write a verified module's published source, every other published file its source map
 * points into, and the source map itself, translated so each position names the file by
 * the SHA-256 of the PUBLISHED text (the compiler hashed the text it compiled; the offsets
 * are the same in both, because blanking keeps every byte's place).
 */
function writeVerified({ replayDir, m, r, build }) {
  const byCompiledHash = new Map();
  for (const f of build.files.values()) {
    byCompiledHash.set(sha256(f.compiled), f);
  }
  const fileOf = (hash) => {
    const f = byCompiledHash.get(hash);
    if (!f) throw new Error(`the source map of 0x${m.address}::${m.module} names a file `
      + `(${hash}) the build did not compile`);
    return f;
  };
  const rel = (f) => `0x${f.account}/source/${f.module}.move`;
  const used = new Map();
  const loc = (l) => {
    const f = fileOf(l.fileHash);
    const h = sha256(f.published);
    used.set(h, f);
    return { file_hash: h, start: l.start, end: l.end };
  };
  const sm = r.sourceMap;
  const own = fileOf(sm.definitionLocation.fileHash);
  if (own.account !== m.address || own.module !== m.module) {
    throw new Error(`the source map of 0x${m.address}::${m.module} is defined in `
      + `${rel(own)}`);
  }
  const doc = {
    format: SOURCE_MAP_FORMAT,
    module_name: [`0x${m.address}`, m.module],
    bytecode_sha256: sha256(m.mv),
    definition_location: loc(sm.definitionLocation),
    function_map: Object.fromEntries(sm.functionMap.map(([idx, fn]) => [String(idx), {
      definition_location: loc(fn.definitionLocation),
      parameters: fn.parameters.map(([n, l]) => [n, loc(l)]),
      locals: fn.locals.map(([n, l]) => [n, loc(l)]),
      code_map: Object.fromEntries(fn.codeMap.map(([pc, l]) => [String(pc), loc(l)])),
      is_native: fn.isNative,
    }])),
  };
  doc.source_files = Object.fromEntries([...used.entries()]
    .sort(([, a], [, b]) => (rel(a) < rel(b) ? -1 : 1)).map(([h, f]) => [h, rel(f)]));
  for (const f of used.values()) {
    const p = join(replayDir, rel(f));
    mkdirSync(join(p, '..'), { recursive: true });
    writeFileSync(p, f.published);
  }
  const map = `0x${m.address}/source/${m.module}.json`;
  writeFileSync(join(replayDir, map), `${JSON.stringify(doc)}\n`);
  return { own: rel(own), map, all: Object.values(doc.source_files) };
}

// ── WHAT A ROW SAYS ──────────────────────────────────────────────────────────────────

/**
 * The row's `artifacts[]` entry for one module of a resolution report. `resolved` is true
 * for a `verified` module and for nothing else; every other outcome says why the module's
 * steps stay on its disassembly, in Source-Resolution.md §4's terms ("not found": nothing
 * was published; "no match": something was, and is discarded).
 */
export function artifactFromResolution(m, ledgerVersion) {
  const where = `${shortAddress(normalizeAddress(m.address))}::${m.module}`;
  const base = { address: m.address, contractClassId: m.codeHash };
  if (m.outcome === 'verified') {
    const b = m.build ?? {};
    return {
      ...base,
      resolved: true,
      origin: `the source ${m.package} (upgrade ${m.upgradeNumber}) published in `
        + `${PACKAGE_REGISTRY} at ${shortAddress(normalizeAddress(m.address))}`,
      corroboration: 'the chain itself',
      reason: `Verified, exact match: the source of package ${m.package} (upgrade `
        + `${m.upgradeNumber}) as published on chain at ledger version ${ledgerVersion} compiles `
        + `with ${b.compiler ?? 'the Aptos CLI'} (Move compiler ${b.compilerVersion}, language `
        + `${b.languageVersion}, bytecode v${b.bytecodeVersion}, the ${b.profile} build profile) `
        + `to exactly the bytes of ${where} the chain held at that version. Its steps are `
        + 'positioned in that source by the compiler\'s source map for those bytes, and its '
        + 'locals carry their source names.'
        + (b.specificationsChanged > 0
          ? ` The package was published without its .spec.move files, so ${b.specificationsChanged} `
            + 'specification construct(s) naming them were set aside to compile it; '
            + 'specifications generate no code, and the bytes are equal.'
          : ''),
    };
  }
  const why = {
    'no-registry': 'its account holds no package registry',
    'no-package': 'no package in its account\'s registry names it',
    'source-not-published': 'no source was published for it',
    'dependency-source-not-published': 'its package depends on one published without source',
    'compile-failed': 'its published source does not compile',
    'bytecode-mismatch': 'its published source compiles to other bytes, so the source is '
      + 'discarded',
  }[m.outcome] ?? m.outcome;
  return {
    ...base,
    resolved: false,
    origin: null,
    corroboration: null,
    reason: `No verified source for module ${where}: ${why} (${m.reason}). Its steps are `
      + 'positioned against the disassembly of its bytecode as the chain held it at version '
      + `${ledgerVersion}, identified by the SHA-256 of that bytecode.`,
  };
}
