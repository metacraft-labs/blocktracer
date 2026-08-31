// Entity index over a built `dist/`.
//
// Named views are semantic ("the newest block", "the transaction with the most
// content"), not hash-literal. The demo data plane is a pure function of a
// fixed seed, so the hashes are stable — but hard-coding them into the view
// list would mean a seed change silently renames every image and quietly
// re-points every baseline. Resolving them here instead keeps the view NAMES
// stable across a reseed, which is the property the baselines actually need.
//
// Selection is deterministic: blocks by descending height, transactions in
// block order, everything else lexicographic.

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function buildEntityIndex(distDir) {
  const registryPath = join(distDir, "registry", "chains.v1.json");
  if (!existsSync(registryPath)) {
    throw new Error(
      `no data plane at ${distDir} (missing registry/chains.v1.json) — run the exporter first`,
    );
  }
  const registry = readJson(registryPath);
  const chains = Object.keys(registry.chains).sort();
  if (chains.length === 0) throw new Error(`registry lists no chains`);

  const byChain = {};
  for (const chain of chains) {
    const current = readJson(join(distDir, "d", chain, "current.json"));

    // The generation's own statement about WHOSE DATA this is
    // (`components/provenance.nim`). Read from the published summary rather
    // than guessed from the slug, for the same reason the product reads it
    // there: keying on the name would survive exactly until a chain was
    // renamed, at which point every view selected by "the real one" would
    // silently be capturing the synthetic one. `kind` is the field that
    // decides the banner's tone, so it is the field the harness selects on.
    const summaryPath = join(distDir, "d", chain, "g", current.generation, "summary.json");
    const provenance = existsSync(summaryPath)
      ? (readJson(summaryPath).provenance ?? null)
      : null;

    // Blocks, newest first, from the on-disk block objects.
    const blockDir = join(distDir, chain, "block");
    const blockHashes = existsSync(blockDir)
      ? readdirSync(blockDir).filter((h) => h.startsWith("0x")).sort()
      : [];
    const blocks = blockHashes
      .map((hash) => readJson(join(distDir, "d", chain, "block", `${hash}.json`)))
      .sort((a, b) => b.height - a.height || a.hash.localeCompare(b.hash));

    // Transactions in block order (newest block first, index order within it).
    const txs = [];
    for (const b of blocks) {
      for (const hash of b.transactions) {
        txs.push({ hash, block: b.hash, height: b.height });
      }
    }

    // Trace availability per transaction, read from the TraceSelection
    // overlay at the generation's pinned version. The debugger views are
    // selected by what a transaction's trace IS — a view named "the divergent
    // session" has to be captured against a divergent trace, and the demo
    // tree's first transaction in block order happens to be an on-demand one.
    // Reading the overlay is how the view list stays semantic across a reseed
    // instead of pinning a hash that would rot.
    // Published manifests, indexed by the transaction they belong to.
    //
    // A manifest lives at `/t/{a}/{b}/{traceArtifactId}/manifest.json`, and the
    // id is DERIVED from the execution input plus the recorder pin — so finding
    // one by transaction means either reimplementing `deriveTraceArtifactId` in
    // JavaScript or reading what was published. This reads what was published.
    // Duplicating the derivation would put a second implementation of a
    // cross-repo identity rule in the capture harness, where it would rot
    // silently: the views would still resolve, against the wrong artifacts.
    const manifestsByTx = {};
    const artifactRoot = join(distDir, "t");
    if (existsSync(artifactRoot)) {
      const walk = (dir) => {
        for (const e of readdirSync(dir, { withFileTypes: true })) {
          const p = join(dir, e.name);
          if (e.isDirectory()) walk(p);
          else if (e.name === "manifest.json") {
            const m = readJson(p);
            (manifestsByTx[m.tx] ??= []).push(m);
          }
        }
      };
      walk(artifactRoot);
    }

    const tsv = current.traceSelectionVersion ?? "1";
    for (const t of txs) {
      const shard = t.hash.slice(2, 6);
      const overlayPath = join(distDir, "d", chain, "ts", tsv, shard, `${t.hash}.json`);
      t.availability = null;
      t.executions = [];
      t.reconstructed = false;

      // The transaction's own immutable facts. `outcome` is what decides
      // whether the event log's fifth kind (`evRevert`) has anything to render,
      // and the three density figures are what let `tx-detail--dense` pick its
      // subject by CONTENT rather than by position — the same rule the trace
      // views already follow, for the same reason.
      const factsPath = join(distDir, "d", chain, "tx", shard, `${t.hash}.json`);
      t.outcome = null;
      t.density = 0;
      t.roleCount = 0;
      t.costRowCount = 0;
      t.payloadRawLength = 0;
      if (existsSync(factsPath)) {
        const f = readJson(factsPath);
        t.outcome = f.outcome?.overall ?? null;
        t.roleCount = (f.roles ?? []).length;
        t.costRowCount = (f.cost ?? []).length;
        t.payloadRawLength = (f.payload?.raw ?? "").length;
        // The three axes `tx-detail--dense`'s must-show names, in one ordering
        // key. Deliberately not just the payload length: a page is dense
        // because of how many REGIONS it carries as well as how long the
        // longest one is.
        t.density = t.roleCount + t.costRowCount + t.payloadRawLength;
      }

      // §14's "Trace truncated": the recorder reached the profile's budget, so
      // the recording's ending is missing. Published in the manifest, and read
      // here rather than inferred — the overlay does not carry it, because it
      // is a fact about the RECORDING and not about the selection.
      t.truncated = (manifestsByTx[t.hash] ?? []).some((m) => m.execution?.truncated === true);

      // ── What a §6.0a deep link into this transaction can say ─────────────
      //
      // `traceContentHash` is what a link's `c` witnesses (Debugger-Integration
      // §6.0), and the anchors are what its `a` is resolved against. Both are
      // read from what was PUBLISHED and from what the route actually rendered,
      // for the reason everything else in this file is: a view named "the link
      // whose anchor no longer resolves" has to be captured against an anchor
      // that genuinely does not resolve, and a literal `call:0.0.2.7` in
      // views.mjs would be a claim about the fixture that nothing re-checks.
      //
      // The anchors come off the RENDERED debug page rather than out of the
      // data plane because that is where they exist: `deeplink_landing`
      // computes a frame's `call:` path from the call trace's own shape, and
      // the served page is the only artefact that has that shape. It is also
      // exactly the document `hydrate.announceLanding` resolves against, so
      // what this reads and what the browser will read are one list.
      t.traceContentHash = (manifestsByTx[t.hash] ?? [])[0]?.container?.hash ?? "";
      t.callAnchors = [];
      t.eventAnchors = [];
      t.currentStep = null;
      const debugPage = join(distDir, chain, "tx", t.hash, "debug", "index.html");
      if (existsSync(debugPage)) {
        const html = readFileSync(debugPage, "utf8");
        for (const m of html.matchAll(
          /class="(ctrow|evrow)[^"]*"[^>]*?data-step="(\d+)" data-anchor="([^"]*)"/g,
        )) {
          const entry = { step: Number(m[2]), anchor: m[3] };
          if (m[3].length === 0) continue;
          (m[1] === "ctrow" ? t.callAnchors : t.eventAnchors).push(entry);
        }
        const cur = /class="ctrow[^"]*\bcur\b[^"]*" data-step="(\d+)"/.exec(html);
        if (cur) t.currentStep = Number(cur[1]);
      }

      if (!existsSync(overlayPath)) continue;
      const overlay = readJson(overlayPath);
      // Single-execution transactions carry `trace`; split ones carry
      // `executions` (Data-Contract's TraceSelection overlay).
      const execs = overlay.trace ? [overlay.trace] : (overlay.executions ?? []);
      t.executions = execs;
      // The headline is the strongest availability among the executions, in
      // the same order `bestTrace` uses, so a transaction whose private half
      // is absent and whose public half is ready reads as `ready` here too.
      for (const want of ["ready", "divergent", "onDemand"]) {
        if (execs.some((e) => e.availability === want)) { t.availability = want; break; }
      }
      if (t.availability === null && execs.length > 0) {
        t.availability = execs[0].availability ?? null;
      }
      // Orthogonal to availability (Trace-Artifacts §2.3a): a trace can be
      // `ready` AND heuristically reconstructed, and the route says so on the
      // identity bar. The flagship `debugger` view wants the plain case.
      t.reconstructed = execs.some((e) => e.reconstructed === true);
    }

    const addrDir = join(distDir, chain, "address");
    const addresses = existsSync(addrDir)
      ? readdirSync(addrDir).filter((a) => a.startsWith("0x")).sort()
      : [];

    // Per address: the segments its generation lists, the code hashes bound to
    // it, and whether any of those hashes has a published source bundle.
    //
    // Read from the data plane rather than from the rendered page, and by the
    // same rule as the trace availability above: a view named "the verified
    // source browser" has to be captured against a contract that HAS one, and
    // a view named "no verified source" against one that does not. Picking
    // either by position would re-point both the first time the seed moved,
    // and the second would silently photograph a verified contract.
    const gen = current.generation;
    const details = {};
    for (const address of addresses) {
      const shard = address.slice(2, 6);
      const indexPath = join(distDir, "d", chain, "g", gen, "addr", shard, `${address}.json`);
      const entry = { address, segments: [], codeHashes: [], verified: false };
      if (existsSync(indexPath)) {
        entry.segments = readJson(indexPath).segments ?? [];
        for (const segRel of entry.segments) {
          const segPath = join(distDir, segRel);
          if (!existsSync(segPath)) continue;
          for (const hash of readJson(segPath).transactions ?? []) {
            const factsPath = join(distDir, "d", chain, "tx", hash.slice(2, 6), `${hash}.json`);
            if (!existsSync(factsPath)) continue;
            for (const edge of readJson(factsPath).codeEdges ?? []) {
              if (edge.address === address && !entry.codeHashes.includes(edge.codeHash)) {
                entry.codeHashes.push(edge.codeHash);
              }
            }
          }
        }
      }
      entry.verified = entry.codeHashes.some((h) =>
        existsSync(join(distDir, "src", chain, h, "current.json")));
      details[address] = entry;
    }

    byChain[chain] = {
      chain, current, blocks, txs, addresses, addressDetails: details, provenance,
      provenanceKind: provenance?.kind ?? "",
    };
  }

  return {
    distDir,
    chains,
    primaryChain: chains[0],
    byChain,
    chain(name) {
      const c = byChain[name ?? chains[0]];
      if (!c) throw new Error(`no such chain in the data plane: ${name}`);
      return c;
    },

    /** The distinct provenance kinds the tree publishes, sorted.
     *
     *  `check-coverage.mjs` asserts a view exists for every one of them. That
     *  is the assertion that would have caught the gap this function was added
     *  for: the tree gained two `live-capture` chains, every named view still
     *  resolved through `primaryChain` — `chains.sort()[0]`, the synthetic one
     *  — and the inventory check reported full coverage because it had no
     *  per-chain entry to miss. A kind with no view is now a failure. */
    provenanceKinds() {
      return [...new Set(chains.map((c) => byChain[c].provenanceKind).filter(Boolean))].sort();
    },

    /** The single chain whose generation published `kind`, or a throw.
     *
     *  Throws on BOTH zero and more than one, because both make the view's
     *  name a lie in a way a fallback would hide: no chain means the image
     *  would be of something else, and two means the view silently picks one
     *  and re-points the first time a chain is added. */
    chainWithProvenance(kind) {
      const hits = chains.filter((c) => byChain[c].provenanceKind === kind);
      if (hits.length === 0) {
        const seen = [...new Set(chains.map((c) => byChain[c].provenanceKind || "(none)"))];
        throw new Error(
          `no chain in the data plane publishes provenance kind "${kind}" ` +
          `(present: ${seen.join(", ")})`);
      }
      if (hits.length > 1) {
        throw new Error(
          `${hits.length} chains publish provenance kind "${kind}" (${hits.join(", ")}) — ` +
          `a view selecting by kind alone would be ambiguous; name the slug`);
      }
      return byChain[hits[0]];
    },
  };
}

// ── Selectors used by views.mjs ────────────────────────────────────────────

/** Newest block on the primary chain. */
export const headBlock = (ix) => ix.chain().blocks[0];

/** Nth block from the head (0 = head). */
export const nthBlock = (n) => (ix) => {
  const b = ix.chain().blocks[n];
  if (!b) throw new Error(`data plane has no block at offset ${n}`);
  return b;
};

/** Nth transaction in block order (0 = first tx of the newest block). */
export const nthTx = (n) => (ix) => {
  const t = ix.chain().txs[n];
  if (!t) throw new Error(`data plane has no transaction at offset ${n}`);
  return t;
};

/** First indexed address. */
export const firstAddress = (ix) => {
  const a = ix.chain().addresses[0];
  if (!a) throw new Error(`data plane indexes no addresses`);
  return a;
};

/** The first transaction in block order whose headline trace availability is
 *  `want` — `"ready"`, `"divergent"`, `"onDemand"`, `"absent"` … .
 *
 *  Throws rather than falling back. A debugger view captured against a
 *  transaction that has no trace would photograph the on-demand state and be
 *  filed under `debugger`, which is precisely the "an image a reviewer would
 *  mistake for a styled page" failure `check-coverage.mjs` exists to prevent.
 */
export const txWithAvailability = (want, { reconstructed = null } = {}) => (ix) => {
  const t = ix.chain().txs.find(
    (t) => t.availability === want &&
           (reconstructed === null || t.reconstructed === reconstructed));
  if (!t) {
    const seen = [...new Set(ix.chain().txs.map((t) => t.availability))].join(", ");
    throw new Error(
      `data plane has no transaction whose trace is "${want}"` +
      (reconstructed === null ? "" : ` with reconstructed=${reconstructed}`) +
      ` (present: ${seen || "none"})`);
  }
  return t;
};

/** The first transaction in block order whose OUTCOME is `want`
 *  (`"reverted"`, `"succeeded"`, `"partial"`, `"failedWithEffects"`) and whose
 *  trace opens a session, so the outcome has a debugging surface to appear on.
 *
 *  `debugger--event-log` renders five entry kinds and the fifth, `evRevert`, is
 *  appended off this outcome. Until the demo tree carried a reverted
 *  transaction the pane could show four, and it was RIGHT to refuse the fifth:
 *  the Aztec split's `partial` is both halves succeeding, and drawing a failed
 *  constraint over it would be the pane inventing an event the trace never
 *  carried. So this selector throws rather than falling back to `partial` —
 *  falling back is exactly the pretence the renderer already declines. */
export const txWithOutcome = (want) => (ix) => {
  const t = ix.chain().txs.find(
    (t) => t.outcome === want &&
           (t.availability === "ready" || t.availability === "divergent"));
  if (!t) {
    const seen = [...new Set(ix.chain().txs.map((t) => t.outcome))].join(", ");
    throw new Error(
      `data plane has no transaction whose outcome is "${want}" with a trace ` +
      `that opens a session (outcomes present: ${seen || "none"})`);
  }
  return t;
};

/** The transaction whose RECORDING hit the profile's budget — §14's "Trace
 *  truncated" row, read from the manifest's `execution.truncated`.
 *
 *  Throws rather than falling back to any session at all, because the failure
 *  it guards against is silent: an untruncated session captured under this
 *  name is a photograph of a page with no banner on it, filed under a view
 *  whose whole must-show list is about the banner. That is a missing subject
 *  reported as a design finding, which is the specific waste
 *  `check-coverage.mjs` and these selectors exist to prevent. */
export const txWithTruncatedTrace = (ix) => {
  const t = ix.chain().txs.find((t) => t.truncated);
  if (!t) {
    throw new Error(
      `data plane publishes no manifest with execution.truncated — the §14 ` +
      `truncation banner would have no subject`);
  }
  return t;
};

/** Every transaction the transaction route serves as the METADATA PAGE rather
 *  than as a session (Page-Descriptions §7.0 rows 2 and 3): no execution whose
 *  trace is `ready` or `divergent`. */
const tracelessTxs = (ix) =>
  ix.chain().txs.filter(
    (t) => t.availability !== "ready" && t.availability !== "divergent");

/** The first traceless transaction in block order — `tx-detail`'s subject. */
export const firstTracelessTx = (ix) => {
  const t = tracelessTxs(ix)[0];
  if (!t) throw new Error(`data plane has no transaction without a session`);
  return t;
};

/** The DENSEST traceless transaction — `tx-detail--dense`'s subject.
 *
 *  Two properties, and the second is the point. It picks by content, so a
 *  reseed cannot leave the dense view photographing an average page. And it
 *  refuses to return the same transaction `firstTracelessTx` returns: after
 *  §7.0 the metadata page is served only where there is no session, and while
 *  the tree held exactly one such transaction this view had nowhere to point —
 *  capturing that one URL twice would answer VD.4's
 *  `verify_transaction_page_holds_at_extreme_content` with a duplicate of
 *  `tx-detail`, which is a green capture that verifies nothing. */
export const densestTracelessTx = (ix) => {
  const all = tracelessTxs(ix);
  if (all.length < 2) {
    throw new Error(
      `data plane has ${all.length} transaction(s) without a session, and the ` +
      `dense metadata page needs a SECOND one: the first is \`tx-detail\`'s own ` +
      `subject, so capturing it here would duplicate that view rather than ` +
      `exercise extreme content`);
  }
  const densest = all.reduce((a, b) => (b.density > a.density ? b : a));
  if (densest.hash === all[0].hash) {
    throw new Error(
      `the densest traceless transaction is also the first one in block order, ` +
      `which is \`tx-detail\`'s subject — \`tx-detail--dense\` would capture the ` +
      `same URL under a second name`);
  }
  return densest;
};

/** An address the tree binds CODE to, whose code hash does (`want = true`) or
 *  does not (`want = false`) have a published source bundle.
 *
 *  Throws rather than falling back, for the reason `txWithAvailability` does:
 *  `contract-source--unverified` captured against a verified contract is an
 *  image a reviewer would grade as the wrong finding, not as a missing one. */
export const contractWithSource = (want) => (ix) => {
  const c = ix.chain();
  const hit = c.addresses.find((a) => {
    const d = c.addressDetails?.[a];
    return d && d.codeHashes.length > 0 && d.verified === want;
  });
  if (!hit) {
    throw new Error(
      `data plane has no contract address whose source bundle is ` +
      `${want ? "published" : "absent"} ` +
      `(addresses with code: ${
        c.addresses.filter((a) => (c.addressDetails?.[a]?.codeHashes.length ?? 0) > 0).length})`);
  }
  return hit;
};

/** An address whose history the generation splits across more than one
 *  block-range segment — the case the cursor pager exists for, and the only
 *  one where "Older" renders at all. */
export const addressWithSegments = (least) => (ix) => {
  const c = ix.chain();
  const hit = c.addresses.find((a) => (c.addressDetails?.[a]?.segments.length ?? 0) >= least);
  if (!hit) throw new Error(`data plane indexes no address with >= ${least} segments`);
  return hit;
};

/** The id of the nth segment of an address's history, as it appears in the
 *  paged URL — read out of the published path, never recomputed. */
export const segmentIdOf = (address, n) => (ix) => {
  const segs = ix.chain().addressDetails?.[address]?.segments ?? [];
  if (segs.length <= n) throw new Error(`${address} has no segment at offset ${n}`);
  return segs[n].split("/").pop().replace(/\.json$/, "");
};

/** The transaction with more than one execution — the Aztec private/public
 *  split, which is the case the metadata pane's execution list exists for. */
export const txWithSplitExecutions = (ix) => {
  const t = ix.chain().txs.find((t) => (t.executions?.length ?? 0) > 1);
  if (!t) throw new Error(`data plane has no multi-execution transaction`);
  return t;
};

// ── §6.0a deep links, derived from the published trace ─────────────────────
//
// The five branches of the resolution precedence are selected by what a link
// SAYS against what the trace IS — a witness that agrees or disagrees, an
// anchor that resolves, one that only has an enclosing frame, one that has
// neither. Every one of the four inputs below is computed from the tree, so
// none of them can drift into naming a branch other than the one it selects.

/** §6.0's content witness for a transaction's trace: the leading 12 hex digits
 *  of the container hash's digest, algorithm tag dropped
 *  (`blocktracer_client/deeplink.witnessFor`). Empty for a traceless one, which
 *  is `absent` and is a legitimate input to step 1. */
export const witnessOf = (tx) => {
  const h = tx.traceContentHash ?? "";
  if (h.length === 0) return "";
  const i = h.indexOf(":");
  return (i < 0 ? h : h.slice(i + 1)).toLowerCase().slice(0, 12);
};

/** A witness that is well-formed and DISAGREES — §6.0's `differs`, the verdict
 *  that means "the trace was regenerated since this link was made".
 *
 *  Derived from the real one by advancing every hex digit, rather than written
 *  down: a literal could silently become the real witness after a reseed, and
 *  the two views that depend on disagreeing would then quietly capture an
 *  exact hit and be graded for a sentence that was correctly absent. */
export const staleWitnessOf = (tx) => {
  const w = witnessOf(tx);
  if (w.length === 0) throw new Error(`${tx.hash}: no content witness to stale`);
  return [...w].map((c) => "123456789abcdef0"["0123456789abcdef".indexOf(c)]).join("");
};

/** The `call:` anchor of the frame the session is served AT — the anchor a
 *  Share taken from this page would actually emit. */
export const currentCallAnchorOf = (tx) => {
  const at = (tx.callAnchors ?? []).find((a) => a.step === tx.currentStep);
  const chosen = at ?? (tx.callAnchors ?? [])[0];
  if (!chosen) throw new Error(`${tx.hash}: rendered no call-trace anchors`);
  return chosen.anchor;
};

/** A `call:` anchor that names a frame this trace does not have, INSIDE one it
 *  does — §6.0a step 4's "the nearest enclosing frame is shown instead".
 *
 *  Built by extending a real frame's path with a sibling index beyond its last
 *  child, and asserted absent, so it stays step 4's subject and cannot decay
 *  into step 3's. */
export const unresolvableChildAnchorOf = (tx) => {
  const parent = currentCallAnchorOf(tx);
  const have = new Set((tx.callAnchors ?? []).map((a) => a.anchor));
  for (let n = 0; n < 64; n++) {
    const candidate = `${parent}.${n}`;
    if (!have.has(candidate)) return candidate;
  }
  throw new Error(`${tx.hash}: every child index under ${parent} resolves`);
};

/** A `log:` anchor past the last event — §6.0a step 5. `log` is one of the two
 *  kinds `resolveAnchor` deliberately gives NO enclosing frame: "nothing
 *  encloses a log index that does not exist", so this reaches the start of
 *  execution rather than step 4. */
export const unresolvableLogAnchorOf = (tx) => {
  const logs = (tx.eventAnchors ?? []).filter((a) => a.anchor.startsWith("log:"));
  return `log:${logs.length + 9}`;
};

// ── Chain-scoped selection (VD.8) ──────────────────────────────────────────
//
// Everything above resolves through `ix.chain()` with no argument, which is
// `chains.sort()[0]`. That was invisible while the tree published one chain
// and became a silent, total gap when it published three: 232 of 280 images in
// the 2026-08-31 regeneration were of `/aztec`, the SYNTHETIC chain, and none
// at all were of `/aztec-testnet` or `/aztec-mainnet`. The real chains are the
// reason the provenance banner exists, and the mainnet arm carries the one
// state the product most needs looked at — a transaction the node still serves
// whose body has been pruned, so it can never be replayed.
//
// The selectors below name their chain. They do not fall back, for the reason
// every selector in this file does not fall back: a view called
// "the mainnet transaction with no trace" that quietly captured a synthetic one
// would be a fabricated image filed under a real name.

/** An index whose UNQUALIFIED chain is `slug`.
 *
 *  Lets every selector above be reused against a named chain instead of being
 *  written twice — `nthTx`, `headBlock` and the rest ask `ix.chain()`, so
 *  rebinding that one method scopes all of them at once. `primaryChain` moves
 *  with it because the route builders interpolate it. */
export const onChain = (slug) => (ix) => ({
  ...ix,
  primaryChain: slug,
  chain: (name) => ix.chain(name ?? slug),
});

/** The chain the generation labelled with provenance `kind`, as a slug. */
export const slugWithProvenance = (kind) => (ix) => ix.chainWithProvenance(kind).chain;

/** A transaction on `slug` that has NO session and never can — the subject of
 *  the zero-trace arm.
 *
 *  It asserts the chain publishes no replayable transaction at all before
 *  picking one, rather than merely finding a traceless transaction on a chain
 *  that has both. The distinction is the whole point of the view: the mainnet
 *  snapshot's own summary says `tracesPublished: 0` because every transaction
 *  in the window is below the node's pruning floor, and the page's job is to
 *  say that permanently rather than to look like a fetch that failed. If that
 *  chain ever gains a trace, this throws and the view is re-pointed by a
 *  person instead of quietly becoming a photograph of an ordinary page. */
export const zeroTraceTxOn = (slug) => (ix) => {
  const c = ix.chain(slug);
  const replayable = c.txs.filter(
    (t) => t.availability === "ready" || t.availability === "divergent");
  if (replayable.length > 0) {
    throw new Error(
      `chain "${slug}" publishes ${replayable.length} replayable transaction(s), ` +
      `so it is no longer the zero-trace arm — re-point this view`);
  }
  const t = c.txs[0];
  if (!t) throw new Error(`chain "${slug}" publishes no transactions at all`);
  return t;
};

/** The first transaction on `slug` whose trace opens a session — the subject of
 *  a debugger view captured against REAL chain data rather than the fixture. */
export const tracedTxOn = (slug) => (ix) => {
  const c = ix.chain(slug);
  const t = c.txs.find((t) => t.availability === "ready");
  if (!t) {
    const seen = [...new Set(c.txs.map((t) => t.availability || "(none)"))].join(", ");
    throw new Error(
      `chain "${slug}" has no transaction whose trace is "ready" ` +
      `(availabilities present: ${seen || "none"})`);
  }
  return t;
};
