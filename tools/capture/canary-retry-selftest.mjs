#!/usr/bin/env node
// Does the canary tell a dead browser from a moved harness?
//
//   node tools/capture/canary-retry-selftest.mjs
//
// `check-canary.mjs` asks ONE question — is the capture harness still
// deterministic? — and until this existed it answered a browser that died
// before producing an image the same way it answers a run that cannot be
// compared: by throwing, which the process reports as exit 2 and a CI job reads
// as the design gate going red.
//
// The two are different sentences, and the repository already makes the
// distinction twice: `tools/journeys/run.mjs` exits 2 for DID NOT RUN rather
// than calling it a product verdict, and `deploy-requeue.yml` re-runs a deploy
// the INFRASTRUCTURE killed while refusing to retry a `failure`. This is that
// distinction for the canary.
//
// THE CLASSIFIER IS TESTED DIRECTLY, not through a browser. What it reads is the
// capture's own output, and the two strings it keys on were taken from CI logs:
// `Target page, context or browser has been closed` and `captured:  0 image(s)`.
// Driving a real Chromium to its death to test this would make the test need the
// very thing whose absence it is about.

import { classifyCapture } from './check-canary.mjs';

let pass = 0, fail = 0;
const ck = (claim, ok) => {
  if (ok) { pass++; console.log(`  [OK]     ${claim}`); }
  else { fail++; console.log(`  [FAILED] ${claim}`); }
};

// The real CI output, trimmed. Both failures looked exactly like this.
const DEAD = `run 1/2 …
  ✗ home__wide__light.png                                browserContext.newPage: Target page, context or browser has been closed
  ✗ blocks-list__wide__light.png                         browser.newContext: Target page, context or browser has been closed
mode:      canary
captured:  0 image(s) -> /var/lib/github-runner-work/mcl-001/blocktracer/blocktracer/screenshots/canary/run-1
FAILED 5:
  home @ wide/light: browserContext.newPage: Target page, context or browser has been closed
`;

// A capture that failed for a reason of its own: images WERE produced.
const REAL = `run 1/2 …
  ✓ home__wide__light.png
mode:      canary
captured:  5 image(s) -> /tmp/canary/run-1
FAILED 1:
  tx-detail @ laptop/light: expected selector .ct-tab to be visible
`;

// A browser that never started at all.
const LAUNCH = `browserType.launch: Executable doesn't exist at /nix/store/…/chrome
captured:  0 image(s) -> /tmp/canary/run-1
`;

console.log('=== canary: a dead browser is not a moved harness ===\n');

ck('exit 0 is ok, whatever the text says',
   classifyCapture(0, DEAD) === 'ok');
ck('a browser that closed with ZERO images captured is did-not-run',
   classifyCapture(1, DEAD) === 'did-not-run');
ck('a browser that never launched, with zero images, is did-not-run too',
   classifyCapture(1, LAUNCH) === 'did-not-run');

// THE CONTROL THAT MAKES THE ARM ABOVE A CLASSIFIER AND NOT A CATCH-ALL. A
// failure that produced images measured something, and the comparison is
// entitled to see it — so it must NOT be swallowed as infrastructure.
ck('a failure that DID capture images is a failure, not did-not-run',
   classifyCapture(1, REAL) === 'failed');
ck('a failure naming no browser trouble is a failure',
   classifyCapture(1, 'captured:  0 image(s)\nFAILED: the exporter wrote no html\n') === 'failed');

// BOTH HALVES ARE REQUIRED, and each alone is not enough: that is what stops a
// genuine zero-image defect in the exporter from being retried forever as
// though a browser had died.
ck('the browser message ALONE is not enough — images were captured',
   classifyCapture(1, 'Target page, context or browser has been closed\ncaptured:  5 image(s)\n') === 'failed');
ck('zero images ALONE is not enough — no browser message',
   classifyCapture(1, 'captured:  0 image(s)\n') === 'failed');

console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} of ${pass + fail} assertion(s)`);
process.exit(fail === 0 ? 0 : 1);
