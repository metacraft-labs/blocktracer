// check-untrusted-text.mjs — decide, over a rendered site, whether a
// chain-controlled payload ever became MARKUP rather than TEXT.
//
// WHY THIS IS A TOKENISER AND NOT A GREP
// --------------------------------------
// `grep -F '<btprobe>'` over the current tree reports three files, and all
// three are FALSE. `isonim/ssr/escape.escapeAttr` escapes `"` and `&` and
// deliberately not `<`, which is correct: inside a double-quoted attribute
// value a `<` is an ordinary character and starts no tag. The three hits are a
// contract name inside `title="…"`, escaped exactly as the HTML spec requires.
//
// A grep therefore cannot tell an escape from a non-escape here, and a gate
// that cannot tell them apart is one that will be deleted the first time it
// cries wolf. So the file is tokenised — quoted attribute values consumed as
// values, <script>/<style> bodies consumed as raw text — and the question asked
// of the RESULT: did an element, an attribute, an event handler or a dangerous
// URL scheme appear that the payload put there?
//
// FOUR DETECTORS, AND ci/test/untrusted-text-test.sh DRIVES EACH ONE RED
// ---------------------------------------------------------------------
//   1. an element whose tag name carries the needle
//   2. an attribute whose NAME carries the needle
//   3. any `on*` event-handler attribute (this site emits none)
//   4. `javascript:`/`vbscript:`/`data:` in href/src/action/poster
//   + a raw-text breakout: the needle closing a <script> or <style> early.
//
// POSITIVE CONTROL, BUILT IN
// --------------------------
// `--min-carriers N` fails the run when fewer than N pages carry the payload at
// all. Without it a gate that stopped rendering the hostile chain — a fixture
// that failed to ingest, an exporter that skipped it — would report a clean
// PASS over 0 measured pages, which is the shape of a check that passes by not
// running.
//
// Usage:
//   node tools/ci/check-untrusted-text.mjs <distDir> [--needle btprobe]
//                                          [--min-carriers N] [--quiet]
// Exit: 0 clean · 1 escapes found · 3 nothing measured · 2 bad usage
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const root = args.find((a) => !a.startsWith("--"));
const flag = (n, d) => {
  const i = args.indexOf("--" + n);
  return i < 0 ? d : args[i + 1];
};
const NEEDLE = flag("needle", "btprobe");
const MIN_CARRIERS = Number(flag("min-carriers", "0"));
const QUIET = args.includes("--quiet");
if (!root || !fs.existsSync(root)) {
  console.error("usage: check-untrusted-text.mjs <distDir> [--needle s] [--min-carriers n]");
  process.exit(2);
}

const URL_ATTRS = ["href", "src", "action", "formaction", "xlink:href", "poster"];
const RAW_TEXT = new Set(["script", "style"]);

function* walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) yield* walk(p);
    else yield p;
  }
}

function tokenise(s) {
  const out = [];
  let i = 0;
  while (i < s.length) {
    const lt = s.indexOf("<", i);
    if (lt < 0) break;
    if (!/[A-Za-z/!?]/.test(s[lt + 1] ?? "")) { i = lt + 1; continue; }
    if (s.startsWith("<!--", lt)) {
      const end = s.indexOf("-->", lt);
      i = end < 0 ? s.length : end + 3;
      continue;
    }
    // Scan to the tag's `>`, honouring quoted attribute values so a `<` or `>`
    // INSIDE one does not end it. This is the whole reason for the tokeniser.
    let j = lt + 1, q = null;
    while (j < s.length) {
      const c = s[j];
      if (q) { if (c === q) q = null; }
      else if (c === '"' || c === "'") q = c;
      else if (c === ">") break;
      j++;
    }
    const body = s.slice(lt + 1, j);
    const nm = /^\/?\s*([A-Za-z0-9:_-]*)/.exec(body);
    const name = (nm?.[1] ?? "").toLowerCase();

    // Attributes are parsed by walking left to right and CONSUMING each value.
    // A regex sweep over the tag body matches words inside quoted values —
    // `content="Block 69357 on hostile …"` yielded a bare `on` attribute, i.e.
    // a fabricated event handler on 41 pages. That was this checker being wrong
    // about a tree that was right, and it is why the parse is a state machine.
    const attrs = [];
    let k = nm[0].length;
    while (k < body.length) {
      while (k < body.length && /[\s/]/.test(body[k])) k++;
      if (k >= body.length) break;
      const ns = k;
      while (k < body.length && /[A-Za-z0-9:_.@\-]/.test(body[k])) k++;
      if (k === ns) { k++; continue; }
      const an = body.slice(ns, k).toLowerCase();
      let ws = k;
      while (ws < body.length && /\s/.test(body[ws])) ws++;
      if (body[ws] !== "=") { attrs.push([an, null]); continue; }
      k = ws + 1;
      while (k < body.length && /\s/.test(body[k])) k++;
      let av = "";
      if (body[k] === '"' || body[k] === "'") {
        const qc = body[k];
        const e = body.indexOf(qc, k + 1);
        av = body.slice(k + 1, e < 0 ? body.length : e);
        k = e < 0 ? body.length : e + 1;
      } else {
        const vs = k;
        while (k < body.length && !/\s/.test(body[k])) k++;
        av = body.slice(vs, k);
      }
      attrs.push([an, av]);
    }
    out.push({ kind: "tag", name, attrs, raw: s.slice(lt, j + 1) });

    if (RAW_TEXT.has(name) && !body.startsWith("/")) {
      const close = s.toLowerCase().indexOf("</" + name, j);
      const e = close < 0 ? s.length : close;
      out.push({ kind: "rawtext", owner: name, text: s.slice(j + 1, e) });
      i = e;
      continue;
    }
    i = j + 1;
  }
  return out;
}

const findings = [];
let files = 0, carriers = 0;

for (const f of walk(root)) {
  if (!f.endsWith(".html")) continue;
  files++;
  const s = fs.readFileSync(f, "utf8");
  if (!s.includes(NEEDLE)) continue;
  carriers++;
  const rel = path.relative(root, f);
  for (const t of tokenise(s)) {
    if (t.kind === "tag") {
      if (t.name.includes(NEEDLE))
        findings.push([rel, "INJECTED ELEMENT <" + t.name + ">", t.raw.slice(0, 140)]);
      for (const [k, v] of t.attrs) {
        if (k.includes(NEEDLE))
          findings.push([rel, "INJECTED ATTRIBUTE " + k + " on <" + t.name + ">", t.raw.slice(0, 140)]);
        if (k.startsWith("on"))
          findings.push([rel, "EVENT HANDLER " + k + " on <" + t.name + ">", t.raw.slice(0, 140)]);
        if (v && URL_ATTRS.includes(k) && /^\s*(javascript|vbscript|data):/i.test(v))
          findings.push([rel, "DANGEROUS URL SCHEME in " + k, v.slice(0, 140)]);
      }
    } else if (t.kind === "rawtext" && t.text.includes(NEEDLE)) {
      if (/<\/\s*(script|style)/i.test(t.text) || t.text.includes("<" + NEEDLE)) {
        const at = t.text.indexOf(NEEDLE);
        findings.push([rel, "PAYLOAD BREAKS OUT OF <" + t.owner + ">",
                       t.text.slice(Math.max(0, at - 60), at + 80)]);
      }
    }
  }
}

if (!QUIET)
  console.log(`check-untrusted-text: ${files} page(s) scanned, ${carriers} carrying '${NEEDLE}'`);

if (carriers < MIN_CARRIERS) {
  console.error(
    `check-untrusted-text: NOTHING MEASURED — ${carriers} page(s) carry the payload, ` +
    `expected at least ${MIN_CARRIERS}. The hostile corpus did not reach the render.`);
  process.exit(3);
}

for (const [f, why, ctx] of findings.slice(0, 40))
  console.error(`  !! ${why}\n     ${f}\n     ${JSON.stringify(ctx)}`);

if (findings.length > 0) {
  console.error(`check-untrusted-text: FAIL — ${findings.length} markup-level escape(s)`);
  process.exit(1);
}
if (!QUIET)
  console.log(`check-untrusted-text: PASS — payload on ${carriers} page(s), never as markup`);
process.exit(0);
