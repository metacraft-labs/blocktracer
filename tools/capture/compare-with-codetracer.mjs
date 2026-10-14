#!/usr/bin/env node
// compare-with-codetracer.mjs — put BlockTracer's debug route beside the
// CodeTracer IDE and capture both, so the resemblance can be LOOKED AT.
//
//   node tools/capture/compare-with-codetracer.mjs --out <dir> [--tx <url>]
//   node tools/capture/compare-with-codetracer.mjs --selftest
//
// ── WHY A SCREENSHOT AND NOT ANOTHER SELECTOR CHECK ────────────────────────
//
// `tools/deploy/check-design-parity.mjs` asks whether every LIVE row of the
// port's reachability register has a rule in the served stylesheet, whether the
// `url()`s resolve, and whether the pages carry a script. Every one of those can
// pass over a page that looks nothing like the IDE: a rule can exist and match
// nothing, an icon can load into an element nobody positioned, and a script can
// hydrate a layout with the wrong chrome. It is an EXISTENCE check, and the
// question "does this closely resemble the CodeTracer IDE" is not an existence
// question.
//
// So this captures both and leaves the images where a person — or a model that
// can read an image — can compare them. It asserts almost nothing on its own;
// its deliverable is the pair, plus the three facts below that a capture can
// settle and prose cannot.
//
// ── THE SUBJECTS ARE DECLARED, AND BOTH NEEDED CHOOSING ───────────────────
//
// BLOCKTRACER. Not every transaction page is an IDE: a transaction with no
// trace renders the degradation view ("No trace, and none possible", ~5,712
// bytes, no `lm_goldenlayout`). Measured 2026-10-14 on the live origin: every
// sampled `/aztec/tx/…/debug` is that page, and every sampled
// `/aztec-testnet/tx/…/debug` is the real workspace (~19,885 bytes, carries
// `lm_goldenlayout`). The default below is one of those, and the tool REFUSES a
// page without the layout rather than photographing the wrong thing.
//
// CODETRACER. `https://ide.codetracer.com/` opens on a WELCOME CARD, not the
// IDE — "Welcome to CodeTracer", recent folders, recent traces. Comparing that
// with a debugger workspace would compare two different screens. Its own copy
// names the way through: "New file works here and opens an editor straight
// away". So the tool clicks it and waits for the editor.
//
// ── WHAT IT ASSERTS ───────────────────────────────────────────────────────
//
// Three things, each of which a picture settles and a stylesheet cannot:
//
//   1. the BlockTracer subject really is the workspace (`lm_goldenlayout`),
//      so the pair is not a comparison against the degradation page;
//   2. the CodeTracer subject really left the welcome card;
//   3. both origins answer `prefers-color-scheme: light` the SAME WAY. They
//      do — both stay dark, byte-for-byte identical to their own dark capture —
//      and that is worth asserting because it looks like a BlockTracer bug
//      until you capture CodeTracer the same way and find it is shared.
//
// Everything else the pair shows is for a reader. The differences standing on
// 2026-10-14 are recorded in `docs/DESIGN-DIVERGENCES-WEB.md`.

import { mkdirSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };

// A transaction whose debug route is the WORKSPACE. See the header for why this
// is declared rather than discovered: the first page a crawl finds on `/aztec`
// is the degradation view, and a capture of it would answer a different
// question while looking like an answer to this one.
export const DEFAULT_BT =
  'https://blocktracer.org/aztec-testnet/tx/'
  + '0x00c859a57de71756b4514a9181fc528d87b3a507a5c4e7a16d1325b3086a731e/debug';
export const DEFAULT_CT = 'https://ide.codetracer.com/';

/** The chrome that says a BlockTracer page is the workspace and not the fallback. */
export const WORKSPACE_MARKERS = ['lm_goldenlayout', 'component-container'];
/** The chrome that says a CodeTracer page has left the welcome card. */
export const EDITOR_MARKERS = ['Navigate to file', 'FILES'];

export function isWorkspace(html) {
  return WORKSPACE_MARKERS.every((m) => html.includes(m));
}
export function leftTheWelcomeCard(html) {
  return !html.includes('Welcome to CodeTracer') && EDITOR_MARKERS.some((m) => html.includes(m));
}

const ARGS = [
  // The determinism flags `lib/determinism.mjs` justifies one by one. Copied
  // rather than imported because that module is about the CANARY's fixed
  // rasterisation and this tool photographs two origins neither of us controls;
  // borrowing its list would imply a determinism claim this cannot make.
  '--force-device-scale-factor=1', '--hide-scrollbars', '--force-color-profile=srgb',
  '--font-render-hinting=none', '--disable-lcd-text', '--disable-gpu',
  '--disable-dev-shm-usage',
];

async function main() {
  const { chromium } = await import('playwright');
  const outDir = arg('out', 'screenshots/codetracer-compare');
  mkdirSync(outDir, { recursive: true });
  const btUrl = arg('tx', DEFAULT_BT);
  const ctUrl = arg('ide', DEFAULT_CT);

  const browser = await chromium.launch({ args: ARGS, chromiumSandbox: false });
  const shots = [];
  let problems = 0;

  for (const theme of ['dark', 'light']) {
    for (const [name, url, after, check] of [
      ['bt-ide', btUrl, null, isWorkspace],
      ['ct-ide', ctUrl, async (page) => {
        const btn = page.locator('text=New file').first();
        if (await btn.count()) { await btn.click(); await page.waitForTimeout(6000); }
      }, leftTheWelcomeCard],
    ]) {
      const ctx = await browser.newContext({
        viewport: { width: 1440, height: 900 }, colorScheme: theme, deviceScaleFactor: 1,
      });
      const page = await ctx.newPage();
      const file = join(outDir, `${name}__${theme}.png`);
      let status = null, ok = false;
      try {
        const r = await page.goto(url, { waitUntil: 'networkidle', timeout: 90000 });
        status = r?.status() ?? null;
        await page.waitForTimeout(3000);
        if (after) await after(page);
        await page.screenshot({ path: file });
        ok = check(await page.content());
      } catch (e) {
        console.error(`  ${name}/${theme}: ${e.message.split('\n')[0]}`);
      }
      await ctx.close();
      const bytes = (() => { try { return statSync(file).size; } catch { return 0; } })();
      shots.push({ name, theme, url, status, bytes, subjectOk: ok, file });
      if (!ok) problems++;
      console.log(`  ${ok ? '[OK]     ' : '[WRONG SUBJECT]'} ${name}/${theme}  HTTP ${status}  ${bytes} B  ${file}`);
    }
  }
  await browser.close();

  // THE LIGHT-MODE ARM. Both origins ignore `prefers-color-scheme: light` and
  // stay dark. Asserted as AGREEMENT rather than as either one's behaviour: it
  // reads as a BlockTracer bug until CodeTracer is captured the same way.
  const same = (n) => {
    const d = shots.find((s) => s.name === n && s.theme === 'dark');
    const l = shots.find((s) => s.name === n && s.theme === 'light');
    if (!d?.bytes || !l?.bytes) return null;
    return Math.abs(d.bytes - l.bytes) <= 64;   // identical up to PNG timestamping
  };
  const btSame = same('bt-ide');
  const ctSame = same('ct-ide');
  console.log('');
  console.log(`  light mode: blocktracer ${btSame ? 'unchanged' : 'changes'}, codetracer ${ctSame ? 'unchanged' : 'changes'}`);
  if (btSame !== null && ctSame !== null && btSame !== ctSame) {
    console.log('  [FAILED]  the two origins DISAGREE about prefers-color-scheme');
    problems++;
  } else if (btSame !== null) {
    console.log('  [OK]      …and they agree, which is what makes it not a defect here');
  }

  console.log('');
  console.log(`captured ${shots.filter((s) => s.bytes > 0).length} image(s) -> ${outDir}`);
  console.log('These are for LOOKING AT. The differences standing on 2026-10-14 are in');
  console.log('docs/DESIGN-DIVERGENCES-WEB.md; this tool does not re-judge them.');
  if (arg('json', null) !== null) console.log(JSON.stringify({ shots, btSame, ctSame }, null, 2));
  return problems === 0 ? 0 : 1;
}

function selftest() {
  let pass = 0, fail = 0;
  const ck = (c, ok) => { if (ok) { pass++; console.log(`  [OK]     ${c}`); } else { fail++; console.log(`  [FAILED] ${c}`); } };
  console.log('=== compare-with-codetracer: do the subject checks discriminate? ===\n');

  const workspace = '<div class="lm_goldenlayout"><div class="component-container">Code</div></div>';
  const fallback = '<main>No trace, and none possible</main>';
  ck('the workspace page is recognised', isWorkspace(workspace));
  ck('the degradation page is NOT — it is the wrong subject', !isWorkspace(fallback));
  ck('…and a page with only ONE marker is not either',
     !isWorkspace('<div class="lm_goldenlayout">no container here</div>'));

  const welcome = '<h1>Welcome to CodeTracer</h1><button>New file</button>';
  const editor = '<input placeholder="Navigate to file or run a :command"><div>FILES</div>';
  ck('the editor is recognised as past the welcome card', leftTheWelcomeCard(editor));
  ck('the welcome card is NOT', !leftTheWelcomeCard(welcome));
  ck('…and a page that is neither is not claimed as the editor',
     !leftTheWelcomeCard('<p>something else entirely</p>'));

  console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} of ${pass + fail} assertion(s)`);
  return fail === 0 ? 0 : 1;
}

if (argv.includes('--selftest')) process.exit(selftest());
main().then((c) => process.exit(c)).catch((e) => {
  console.error(`compare-with-codetracer: ${e.stack ?? e.message}`);
  process.exit(2);
});
