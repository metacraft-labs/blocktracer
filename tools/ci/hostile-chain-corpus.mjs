// hostile-chain-corpus.mjs — derive a HOSTILE chain snapshot from a real
// capture, so the escaping gate has something to measure.
//
// WHY THIS IS DERIVED AND NOT COMMITTED
// -------------------------------------
// The corpus in client/fixtures/chain/ is 12 MB of real captured chain data.
// A committed hostile twin would be a fourth copy of it, would go stale the
// moment the schema moves, and would be a second answer to "what does a
// snapshot look like". This transform reads a real capture and rewrites the
// CHAIN-CONTROLLED strings in it — nothing else — so the hostile fixture is
// always of the same vintage as the corpus it is derived from.
//
// WHAT COUNTS AS CHAIN-CONTROLLED
// -------------------------------
// The fields a contract, a node or an artifact distributor decides the bytes
// of, as opposed to the ones this repository's own capture tool writes:
//
//   * source bundle FILE PATHS and FILE CONTENTS — the largest surface by far,
//     and the one the syntax highlighter and the document tabs read;
//   * a bundle's `origin`, which is where a contract's own name arrives;
//   * every non-structural string on the snapshot — revert reasons, refusal
//     detail, rung explanations, labels, endpoints, versions.
//
// Structural values are left EXACTLY as captured. Poisoning a hash, a path
// reference or an enum spelling does not make the fixture hostile; it makes it
// unpublishable, and an ingest that refuses it measures nothing. That
// distinction was learned the hard way: the first version of this transform
// poisoned `outcome`/`kind`/`origin` on the snapshot as well, and the contract's
// source bundle stopped resolving — so the run passed while the source pane,
// the sink that matters most, was never rendered at all.
//
// Usage:
//   node tools/ci/hostile-chain-corpus.mjs <srcCaptureDir> <destDir> <chainSlug>
import fs from "node:fs";
import path from "node:path";

const [src, dest, slug] = process.argv.slice(2);
if (!src || !dest || !slug) {
  console.error("usage: hostile-chain-corpus.mjs <srcCaptureDir> <destDir> <chainSlug>");
  process.exit(2);
}

// One payload, carrying all four breakouts the checker looks for, so a single
// occurrence anywhere is enough to decide the question:
//   <btprobe>          an element, if `<` survives into text
//   " btprobe=1 x="    an attribute, if `"` survives into an attribute value
//   javascript:…       a scheme, if the value lands in an href/src
//   &btprobe;          an entity, if `&` is not escaped
export const PAYLOAD = '<btprobe>" btprobe=1 x="javascript:btprobe()&btprobe;';

// Keys whose value the ingest keys off. See the header.
const STRUCTURAL_KEYS = new Set([
  "format", "chain", "container", "sourceBundles", "txHash", "hash",
  "codeHash", "artifactHash", "contractClassId", "address", "pathId",
  "capturedAt", "frozenAt", "firstCapturedAt", "measuredAt",
  "kind", "outcome", "shape", "declaredRung", "corroboration",
  // ING-3's closed-set reason is an ENUM SPELLING, exactly like `outcome` and
  // `kind` beside it. Poisoning it does not make the fixture hostile: the
  // ingest refuses a reason outside the closed set by design, so the run would
  // die before rendering anything and would measure nothing — which is the
  // failure this list's header records having already paid for once.
  //
  // The SENTENCE beside it, `reason`, is not here and must not be: that is
  // free text from a producer, it reaches the page verbatim, and it is exactly
  // the kind of string this corpus exists to push through the escaper.
  "refusalReason",
]);

const looksStructural = (s) =>
  /^0x[0-9a-fA-F]*$/.test(s) ||
  /^[0-9]+$/.test(s) ||
  /^\d{4}-\d\d-\d\dT/.test(s) ||
  /^(ct|sources|instructions|calltrace|positions)\//.test(s);

function poison(v, key) {
  if (typeof v === "string")
    return STRUCTURAL_KEYS.has(key) || looksStructural(v) ? v : v + PAYLOAD;
  if (Array.isArray(v)) return v.map((x) => poison(x, key));
  if (v && typeof v === "object") {
    const o = {};
    for (const k of Object.keys(v)) o[k] = poison(v[k], k);
    return o;
  }
  return v;
}

fs.rmSync(dest, { recursive: true, force: true });
fs.cpSync(src, dest, { recursive: true });

// ── the snapshot ───────────────────────────────────────────────────────────
const snap = JSON.parse(fs.readFileSync(path.join(src, "snapshot.json"), "utf8"));
const out = poison(snap, "");
// The slug is NOT poisoned. It is a directory name and a URL segment written by
// this repository's own capture configuration, not by a chain — a different
// question from this gate's, and one whose answer is a path, not an escape.
out.provenance.chain = slug;
out.provenance.label = "Hostile corpus " + PAYLOAD;
fs.writeFileSync(path.join(dest, "snapshot.json"), JSON.stringify(out, null, 1));

// The artifact-resolution sidecar names the chain it resolves and the ingest
// refuses to attach one chain's resolution to another's transactions, so the
// slug has to move with it.
const arPath = path.join(dest, "artifact-resolution.json");
if (fs.existsSync(arPath)) {
  const ar = JSON.parse(fs.readFileSync(arPath, "utf8"));
  const retag = (o) => {
    if (Array.isArray(o)) o.forEach(retag);
    else if (o && typeof o === "object")
      for (const k of Object.keys(o)) {
        if (k === "chain" && typeof o[k] === "string") o[k] = slug;
        else retag(o[k]);
      }
  };
  retag(ar);
  fs.writeFileSync(arPath, JSON.stringify(ar));
}

// ── the source bundles ─────────────────────────────────────────────────────
//
// The real path is KEPT and poisoned in place rather than replaced, so the
// recording's position stream still resolves to a document and the source pane
// still renders. A poisoned TWIN is added beside it for the tab strip, the file
// tree and the anchor mangling to carry as well.
const sdir = path.join(dest, "sources");
let poisonedBundles = 0;
if (fs.existsSync(sdir)) {
  for (const f of fs.readdirSync(sdir)) {
    const p = path.join(sdir, f);
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    for (const b of j.bundles ?? []) {
      if (b.origin) b.origin = b.origin + PAYLOAD;
      if (b.files) {
        const nf = {};
        for (const [k, v] of Object.entries(b.files)) {
          nf[k] = "// " + PAYLOAD + '\nlet probe = "' + PAYLOAD + '";\n' + v;
          nf[path.dirname(k) + "/" + PAYLOAD + ".nr"] = "// " + PAYLOAD;
        }
        b.files = nf;
      }
      poisonedBundles++;
    }
    fs.writeFileSync(p, JSON.stringify(j));
  }
}

console.log(
  `hostile corpus: ${dest} (chain '${slug}', ${poisonedBundles} source bundle(s) poisoned)`);
