#!/usr/bin/env bash
#
# journeys-refusal-exit-code.sh — a refusal must not be able to fire before the
# code that gives it an exit code.
#
# WHY THIS EXISTS, AND WHY IT IS STATIC RATHER THAN A TEST
# -------------------------------------------------------
# `tools/journeys/run.mjs` distinguishes DID NOT RUN from FAILED by exit code:
# a refusal throws with `e.exitCode = 2`, and `main().catch` is what reads that
# property and passes it to `process.exit`. Every refusal in the journeys layer
# depends on reaching that handler.
#
# CODE AT MODULE SCOPE never reaches it. ES modules evaluate on import, before
# `main()` is called and outside its `try`, so the property is dropped and node
# exits 1 — the same code a genuinely failing journey uses. Measured
# on 2026-09-04: with `tools/capture/node_modules` absent,
# `node tools/journeys/run.mjs` exited **1** while `lib/probe.mjs` was throwing
# an error it had explicitly tagged `exitCode = 2`. A condition built to say
# "did not run" was indistinguishable from a red journey, and the whole
# refusal-versus-failure distinction — which `README.md` documents and
# `lib/site.mjs` raises four times — was silently defeated one layer up.
#
# THIS CANNOT BE A RUNTIME TEST, WHICH IS THE ENTIRE POINT. The state that
# exposes it is "the dependency is missing", and CI always installs the
# dependency, so a regression test for it would pass in CI for the wrong reason
# forever — a check that passes by not running, guarding the very defect class
# this repository is auditing. The scan is therefore static: it reads the source
# and asks WHERE the work sits, which does not require the failure to happen.
#
# WHAT IT LOOKS FOR, AND WHY IT IS NOT JUST `throw`. The first draft flagged a
# module-scope `throw` and reported RESULT: OK against the very commit whose
# defect motivated it, because the real shape was a module-scope `try` whose
# CATCH did the throwing — nested, and so invisible to a depth-zero test. The
# defect is IMPORT-TIME EXECUTABLE WORK; the throw was only its visible end. So
# three constructs are rejected at depth zero: `try` (its body runs on import),
# top-level `await` (same), and a bare `throw`.
#
# WHAT IT ALLOWS. Anything inside a function, class, block or arrow body — that
# is every ordinary refusal, and they all run under `main()`. Declarations are
# untouched: `import`, `export`, `const`, `let`, `function`, `class`, and the
# trailing `main().catch(...)`. A module that cannot continue should export a
# function the runner calls, so the throw happens where `exitCode` is read.
#
# PROVED AGAINST THE REAL DEFECT: run against `5c79f371bfe0^` it reports
# `lib/probe.mjs:46: \`try\` at module scope`, and against the fix it is green.
#
# Usage:
#   bash ci/test/journeys-refusal-exit-code.sh
#   bash ci/test/journeys-refusal-exit-code.sh --root DIR    (for the self-test)

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		root="$(cd "$2" && pwd)"
		shift 2
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done
cd "${root}" || exit 2

scan_dir="tools/journeys"
if [ ! -d "${scan_dir}" ]; then
	echo "no ${scan_dir} under ${root}; this guard has no subject" >&2
	exit 2
fi

echo "=== journeys refusal exit codes — no import-time work at module scope ==="
echo

# The scanner. Node rather than grep, because the question is STRUCTURAL: a
# `throw` is only a problem at brace depth zero, and depth cannot be counted
# without skipping over strings, template literals, regex literals and comments
# that contain braces. `grep -c '^throw'` would miss an indented module-scope
# throw and flag a well-indented one inside a function.
node - "${scan_dir}" <<'NODE'
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const rootDir = process.argv[2];

const files = [];
(function walk(d) {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.isDirectory()) {
      if (e.name === "node_modules" || e.name === "journeys") continue;
      walk(p);
    } else if (e.name.endsWith(".mjs")) files.push(p);
  }
})(rootDir);
files.sort();

// Strip comments and quoted text, replacing each with spaces so that every
// byte offset — and therefore every line number — is preserved exactly.
function blank(src) {
  const out = src.split("");
  let i = 0;
  const n = src.length;
  // `prev` is the last significant character, used to tell a regex literal
  // from a division: `/` after a value divides, after an operator it opens.
  let prev = "";
  const wipe = (from, to) => {
    for (let k = from; k < to && k < n; k++) if (out[k] !== "\n") out[k] = " ";
  };
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "/" && d === "/") {
      let j = i; while (j < n && src[j] !== "\n") j++;
      wipe(i, j); i = j; continue;
    }
    if (c === "/" && d === "*") {
      let j = i + 2; while (j < n && !(src[j] === "*" && src[j + 1] === "/")) j++;
      wipe(i, Math.min(j + 2, n)); i = j + 2; continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < n) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === c) break;
        j++;
      }
      wipe(i, Math.min(j + 1, n)); i = j + 1; prev = "x"; continue;
    }
    if (c === "/" && prev && !"=(,:;[{&|!?+-*%~^<>".includes(prev)) {
      // division, not a regex
      prev = c; i++; continue;
    }
    if (c === "/") {
      let j = i + 1, cls = false;
      while (j < n) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === "[") cls = true;
        else if (src[j] === "]") cls = false;
        else if (src[j] === "/" && !cls) break;
        else if (src[j] === "\n") break;
        j++;
      }
      if (j < n && src[j] === "/") { wipe(i, j + 1); i = j + 1; prev = "x"; continue; }
    }
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  return out.join("");
}

let findings = 0;
let scanned = 0;
for (const f of files) {
  if (!statSync(f).isFile()) continue;
  scanned++;
  const src = readFileSync(f, "utf8");
  const clean = blank(src);
  let depth = 0;
  const lines = clean.split("\n");
  const raw = src.split("\n");
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    // THREE CONSTRUCTS, NOT ONE, AND THE FIRST DRAFT ONLY HAD THE LAST.
    //
    // Written to flag `throw` at depth zero, this guard reported RESULT: OK
    // against the very tree whose defect motivated it. The real shape was
    //
    //     let chromium;
    //     try {
    //       ({ chromium } = captureRequire("playwright"));
    //     } catch (err) {
    //       const e = new Error("playwright is not installed…");
    //       e.exitCode = 2;
    //       throw e;                 // <-- depth 1, inside the catch
    //     }
    //
    // The `throw` is nested, so a depth-zero test cannot see it — but the TRY
    // ITSELF is at module scope, and that is what makes the work happen during
    // ESM evaluation, before `main` exists. The defect is not "a throw in the
    // wrong place", it is IMPORT-TIME EXECUTABLE WORK, of which the throw was
    // only the visible end.
    //
    // So all three are flagged at depth zero:
    //   try     — a module-scope try/catch runs its body on import; if it
    //             rethrows, `e.exitCode` is dropped and node exits 1
    //   await   — top-level await runs on import, same window
    //   throw   — the bare form, which was the original rule
    //
    // Declarations are untouched: `import`, `export`, `const`, `let`,
    // `function`, `class`, and the trailing `main().catch(...)` are all fine.
    const checks = [
      [/(^|[^A-Za-z0-9_$.])try(?![A-Za-z0-9_$])/, "`try` at module scope — its body runs on import"],
      [/(^|[^A-Za-z0-9_$.])await(?![A-Za-z0-9_$])/, "top-level `await` — it runs on import"],
      [/(^|[^A-Za-z0-9_$.])throw(?![A-Za-z0-9_$])/, "`throw` at module scope"],
    ];
    if (depth === 0) {
      for (const [re, why] of checks) {
        if (re.test(line)) {
          findings++;
          console.log(`  [FAILED] ${f}:${li + 1}: ${why}`);
          console.log(`           ${raw[li].trim().slice(0, 100)}`);
          break;
        }
      }
    }
    for (const ch of line) {
      if (ch === "{" || ch === "(" || ch === "[") depth++;
      else if (ch === "}" || ch === ")" || ch === "]") depth--;
    }
  }
}

console.log(`  scanned ${scanned} module(s) under ${rootDir}/`);

// THE NON-VACUITY FLOOR, AND THIS GUARD NEEDED IT LIKE EVERY OTHER SCANNER.
//
// Written without one, and its own contract suite caught it on the first run:
// point the scan at a directory with no modules in it and it printed
// `scanned 0 module(s)` followed by `RESULT: OK`. A scanner that finds nothing
// satisfies every "must not contain" question ever asked of it, which is
// exactly the failure this repository has been auditing all day —
// Verification-Harness-Traps.md trap 6, reproduced by the author of the
// paragraph about it, inside the guard written to prevent a related one.
//
// A rename of `tools/journeys/`, or a build that runs this from the wrong
// directory, is all it would take.
if (scanned === 0) {
  console.log("");
  console.log("  [FAILED] the scan found NO modules — it cannot have checked anything.");
  console.log("           A clean sweep of an empty set is not a clean sweep. Check that");
  console.log(`           ${rootDir}/ is still where the journeys modules live.`);
  process.exit(1);
}

if (findings === 0) {
  console.log("  [OK]     no try, await or throw at module scope: every refusal reaches");
  console.log("           main()'s catch and keeps the code separating DID NOT RUN from FAILED");
  process.exit(0);
}
console.log("");
console.log(`  ${findings} module-scope construct(s) that run on import.`);
console.log("  An ES module evaluates on import, before main() is called and outside the");
console.log("  try whose rejection main().catch reads. So `e.exitCode` is dropped and node");
console.log("  exits 1 — the code a FAILING journey uses, which makes a refusal");
console.log("  indistinguishable from a red run. Defer the work into a function the");
console.log("  runner calls, so the throw happens where the exit code is honoured.");
process.exit(1);
NODE
rc=$?

echo
if [ "${rc}" -eq 0 ]; then
	echo "RESULT: OK"
else
	echo "RESULT: FAILED"
fi
exit "${rc}"
