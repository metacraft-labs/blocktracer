// What a `ledger@<revision>:<id>` citation MEANS, then and now.
//
// B4 and `citation-evidence.mjs` ask the same question and used to answer it
// with two different mechanisms: B4 compared the cited revision against the
// current one, and `citation-evidence.mjs` walked git history and compared the
// FINDING TEXT. This module is the second answer, extracted so B4 can use it,
// because the first one is a proxy and the proxy over-fires.
//
// ── Why the proxy had to go (QUEUED-DECISIONS Q21) ─────────────────────────
//
// B4 asserted revision CURRENCY as a stand-in for the property it actually
// wants: "this citation still means what the comment citing it says". That is
// sound in one direction and badly calibrated in the other. It never misses a
// meaning change, because a meaning change implies a revision bump. But it
// fires on EVERY citation at EVERY ingest, whatever the round touched — and an
// ingest happens whenever any triple is re-reviewed.
//
// Observed, three rounds running, same five sites every time:
//
//   vd10-r1  re-reviewed five debugger triples, touched no tx-detail finding.
//            Revision 2026-08-31.14 -> 2026-09-01.5. Five tx-detail citations
//            red, plus two self-test anchors. All SAFE-RESTAMP.
//   vd10-r2  re-reviewed `debugger--testnet` alone. .5 -> .6. The same five,
//            plus the same two. All SAFE-RESTAMP.
//   vd11-r1  re-reviewed `debugger--testnet` alone. .6 -> .7. The same five.
//            All SAFE-RESTAMP.
//
// The steady-state cost was one human judgement per citation per round on
// citations that had not changed, and the remedy it taught was BULK
// RE-STAMPING — the exact move that would have been catastrophic earlier in
// this campaign, when all 70 sites were MEANING-CHANGED. A tripwire that cries
// wolf trains its reader to disbelieve it.
//
// ── This is strictly stronger than what it replaces, and that is the test ───
//
// The standing rule here is never to resolve a finding by weakening the
// assertion that produced it, so the change has to be measured against that
// rather than asserted past it.
//
//   * RECALL is unchanged. A meaning change alters the finding text at that id,
//     so `MEANING-CHANGED` catches every case the currency proxy caught for the
//     right reason.
//   * PRECISION improves. Citations whose finding is byte-identical at the
//     cited revision and now are no longer reported, because there is nothing
//     wrong with them.
//   * A citation that cannot be resolved at all is treated as WORSE than a
//     stale one, not better: an id that has left the ledger, or a revision that
//     never existed, fails. The old check could not distinguish these from
//     ordinary staleness.
//
// So the set B4 rejects becomes a strict subset of what it rejected before,
// minus exactly the members that were never defects. Nothing it used to catch
// escapes.
//
// ── The one thing that must not happen in CI ────────────────────────────────
//
// Resolving an old revision means reading git history, and `actions/checkout@v4`
// clones at depth 1 by default — which this repository's workflows use. In a
// shallow tree the history simply is not there, and a check that concluded
// "cited-revision-not-in-history" from a missing clone would fail every
// citation in CI for a reason that is about the checkout and not about the
// code.
//
// So absence of history is detected and named, and a citation that cannot be
// verified there falls back to the CURRENCY proxy — today's behaviour exactly.
// CI keeps the check it has; a full checkout gets the better one. What is never
// done is inferring a verdict from evidence that was not available.

import { execFileSync } from "node:child_process";

const git = (root, args) =>
  execFileSync("git", ["-C", root, ...args], { encoding: "utf8", maxBuffer: 1 << 28 });

/** Is enough history present to resolve a past revision of the ledger?
 *
 *  Two ways for the answer to be no, and they are different: not a git tree at
 *  all, and a tree deliberately truncated. Both mean the same thing here. */
export function ledgerHistoryAvailable(root, ledgerRelPath = "reviews/ledger.json") {
  try {
    if (git(root, ["rev-parse", "--is-shallow-repository"]).trim() === "true") {
      return { ok: false, reason: "the repository is a shallow clone, so past ledgers are not in it" };
    }
    const commits = git(root, ["log", "--format=%H", "--", ledgerRelPath])
      .trim().split("\n").filter(Boolean);
    if (commits.length < 2) {
      return {
        ok: false,
        reason: `only ${commits.length} commit(s) touch ${ledgerRelPath} in this checkout`,
      };
    }
    return { ok: true, commits };
  } catch (e) {
    return { ok: false, reason: `git is not usable here (${e.message.split("\n")[0]})` };
  }
}

/** The ledger as it stood at `rev`, or null. Cached per root. */
export function makeLedgerAtRevision(root, ledgerRelPath = "reviews/ledger.json") {
  const cache = new Map();
  return (rev) => {
    if (cache.has(rev)) return cache.get(rev);
    let found = null;
    try {
      const shas = git(root, ["log", "--format=%H", "--", ledgerRelPath])
        .trim().split("\n").filter(Boolean);
      for (const sha of shas) {
        try {
          const L = JSON.parse(git(root, ["show", `${sha}:${ledgerRelPath}`]));
          if (L.ledgerRevision === rev) { found = L; break; }
        } catch { /* a commit where the file did not exist or did not parse */ }
      }
    } catch { /* not a git tree */ }
    cache.set(rev, found);
    return found;
  };
}

/** id -> finding, across every review in a ledger. */
export function indexFindings(L) {
  const m = new Map();
  if (!L) return m;
  for (const r of L.reviews ?? []) {
    for (const f of r.findings ?? []) m.set(f.id, { ...f, reviewer: r.reviewer });
  }
  return m;
}

/**
 * Classify one citation.
 *
 * Verdicts, and what each one means for a checker:
 *
 *   current                       — cites the current revision; only the id
 *                                   needs to exist. Not a finding.
 *   SAFE-RESTAMP                  — the finding at that id is byte-identical at
 *                                   the cited revision and now. The comment
 *                                   still means what it says. NOT a defect.
 *   MEANING-CHANGED               — the finding at that id says something else
 *                                   now. The comment reads as evidence and is
 *                                   not. THE defect B4 exists for.
 *   id-gone-from-current-ledger   — nothing at that id today. Worse than stale.
 *   id-not-in-cited-revision      — the revision existed; the id was not in it.
 *                                   The citation never resolved, at any point.
 *   cited-revision-not-in-history — that revision never existed here. Worse
 *                                   than stale, and only decidable with history.
 *   unverifiable-no-history       — history is absent (shallow CI clone). The
 *                                   caller falls back to the currency proxy.
 *
 * The last three were ONE verdict until B4 started quoting them. Collapsing "the
 * revision is not in history" with "the id was not in that revision" is a
 * diagnosis that sends its reader to look for the wrong thing — and the two want
 * different fixes, which is the same reason `markUnavailable`'s three engine
 * sentences are three strings and not one.
 */
export function classifyCitation({ citedRevision, id, currentRevision, current, at, history }) {
  if (citedRevision === currentRevision) {
    return current.has(id)
      ? { verdict: "current" }
      : { verdict: "id-gone-from-current-ledger", now: null };
  }
  if (!history.ok) return { verdict: "unverifiable-no-history", reason: history.reason };

  const pastLedger = at(citedRevision);
  if (!pastLedger) return { verdict: "cited-revision-not-in-history" };
  const was = indexFindings(pastLedger).get(id);
  const now = current.get(id);
  if (!was) return { verdict: "id-not-in-cited-revision" };
  if (!now) return { verdict: "id-gone-from-current-ledger", was };
  return {
    verdict: was.finding === now.finding ? "SAFE-RESTAMP" : "MEANING-CHANGED",
    was,
    now,
  };
}
