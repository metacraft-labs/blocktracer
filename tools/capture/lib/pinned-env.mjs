// Is this process running in THE PINNED CAPTURE ENVIRONMENT? (VD.0)
//
// Tier 1 of visual-design-iteration.md is an exact-hash check, and its value
// rests entirely on the inputs being fixed. So this module answers one
// question — may the canary's byte-identity be reported as a TIER-1 verdict,
// or only as advisory? — and it answers it by CHECKING, not by believing.
//
// The distinction matters. The previous design took `VD0_IN_CONTAINER=1` at
// face value, which means any caller — including a well-meaning shell alias —
// could promote a host run to a tier-1 pass by exporting one variable. Here the
// environment states its identity AND the paths it claims to be built from, and
// every claim is re-verified against the filesystem and against Playwright's
// own resolution before it is accepted.
//
// THREE OUTCOMES, and only the first is a tier-1 verdict:
//
//   pinned + tier1Capable  — verified pinned inputs on a platform where the
//                            browser owns the rasterisation. Linux only.
//   pinned, NOT tier1      — verified pinned inputs on darwin. The pinned
//                            Chromium still rasterises through the host's
//                            CoreGraphics/CoreText stack, which is not a
//                            pinned input and cannot be made one from inside
//                            Nix. Byte-identity here says the harness repeats
//                            itself on THIS machine; it does not say the hash
//                            measures the product, and darwin<->Linux hashes
//                            are not expected to agree.
//   not pinned             — a bare host. Useful while iterating, never a
//                            tier-1 verdict.
//
// A claim that does not verify lands in the third bucket WITH its reasons
// recorded, so "the wrapper was not actually in effect" is distinguishable
// from "nobody tried".

import { existsSync, statSync } from "node:fs";
import { readFileSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const CAPTURE_DIR = resolvePath(HERE, "..");
const REPO_ROOT = resolvePath(CAPTURE_DIR, "..", "..");

const NIX_STORE = "/nix/store/";

/** Platforms on which a pinned browser build actually owns the rasterisation. */
const TIER1_PLATFORMS = new Set(["linux"]);

const DARWIN_CAVEAT =
  "darwin rasterises through the host compositor (CoreGraphics/CoreText), which no " +
  "derivation can pin; byte-identity here is self-consistency on this machine, not a " +
  "measurement of the product. Produce the tier-1 verdict on Linux.";

function pkgVersion(...candidates) {
  for (const p of candidates) {
    try {
      return JSON.parse(readFileSync(p, "utf8")).version;
    } catch {
      /* try the next */
    }
  }
  return null;
}

/** The `playwright` npm package this process would actually import. */
export function resolvedPlaywrightVersion() {
  return pkgVersion(
    join(CAPTURE_DIR, "node_modules", "playwright", "package.json"),
    join(REPO_ROOT, "node_modules", "playwright", "package.json"),
  );
}

/** The version tools/capture/package.json PINS, which is the intended one. */
export function pinnedPlaywrightVersion() {
  try {
    return JSON.parse(readFileSync(join(CAPTURE_DIR, "package.json"), "utf8"))
      .dependencies.playwright;
  } catch {
    return null;
  }
}

function isStorePath(p) {
  return typeof p === "string" && p.startsWith(NIX_STORE);
}

/**
 * Is `child` genuinely underneath `parent`?
 *
 * A bare `startsWith` is not this question. `/nix/store/xxx-browsers-EVIL/…`
 * begins with `/nix/store/xxx-browsers` and is a DIFFERENT store path, so a
 * prefix test accepts a sibling derivation as though it were the pinned one.
 * The separator is what makes it a containment check.
 */
function isInside(parent, child) {
  return typeof child === "string" && child.startsWith(`${parent}/`);
}

function existsAt(p) {
  try {
    return Boolean(p) && existsSync(p) && Boolean(statSync(p));
  } catch {
    return false;
  }
}

/**
 * Verify the `nix` environment's claims. Returns the list of reasons it does
 * NOT hold; empty means every claim checked out.
 *
 * @param {(mod: string) => any} [resolveBrowser] injection seam for the tests:
 *   given "chromium", return Playwright's resolved executable path.
 */
function verifyNixClaims(env, chromiumExecutablePath) {
  const problems = [];

  const browsers = env.VD0_BROWSERS_PATH;
  const fontsConf = env.VD0_FONTS_CONF;

  if (!isStorePath(browsers))
    problems.push(`VD0_BROWSERS_PATH is not a /nix/store path (${browsers ?? "unset"})`);
  else if (!existsAt(browsers))
    problems.push(`VD0_BROWSERS_PATH does not exist: ${browsers}`);

  // The claim has to be the one Playwright will actually honour, not a
  // decorative duplicate.
  if (env.PLAYWRIGHT_BROWSERS_PATH !== browsers)
    problems.push(
      `PLAYWRIGHT_BROWSERS_PATH (${env.PLAYWRIGHT_BROWSERS_PATH ?? "unset"}) does not match ` +
        `the claimed pinned bundle (${browsers ?? "unset"}); the browser that runs would not be the pinned one`,
    );

  if (!isStorePath(fontsConf))
    problems.push(`VD0_FONTS_CONF is not a /nix/store path (${fontsConf ?? "unset"})`);
  else if (!existsAt(fontsConf))
    problems.push(`VD0_FONTS_CONF does not exist: ${fontsConf}`);

  if (env.FONTCONFIG_FILE !== fontsConf)
    problems.push(
      `FONTCONFIG_FILE (${env.FONTCONFIG_FILE ?? "unset"}) does not match the claimed pinned ` +
        `config (${fontsConf ?? "unset"}); the browser would fall back to host fonts`,
    );

  if (!env.VD0_ENV_ID) problems.push("VD0_ENV_ID is unset; the environment has no recorded identity");

  // ── The identity has to be BACKED, not just present ──────────────────────
  // VD0_ENV_ID is the whole basis on which two hashes are declared comparable:
  // "a stored baseline can say which environment it came from". Checking only
  // that it is non-empty reproduces, one level up, the exact failure this
  // module exists to remove — a bare assertion nobody re-derives. The
  // derivation writes a manifest of the pin next to the id, so the id can be
  // required to agree with it.
  //
  // This is a DRIFT check, not an anti-forgery one: anything that can set the
  // variables can also write a file. What it catches is the case that actually
  // happens — a wrapper, a CI env block or a hand-assembled shell whose
  // exported paths have moved away from the manifest they claim to describe,
  // which would let two different environments record the same id.
  const manifestPath = env.VD0_ENV_MANIFEST;
  if (!manifestPath) {
    problems.push(
      "VD0_ENV_MANIFEST is unset; the claimed VD0_ENV_ID is backed by nothing, so nothing " +
        "says which pinned inputs that id stands for",
    );
  } else {
    const m = readManifest(manifestPath);
    if (!m) {
      problems.push(`VD0_ENV_MANIFEST is not readable JSON: ${manifestPath}`);
    } else {
      const disagree = [];
      if (env.VD0_ENV_ID && m.id !== env.VD0_ENV_ID)
        disagree.push(`id (manifest ${m.id ?? "unset"} vs exported ${env.VD0_ENV_ID})`);
      if (browsers && m.browsers !== browsers)
        disagree.push(`browsers (manifest ${m.browsers ?? "unset"} vs exported ${browsers})`);
      if (fontsConf && m.fontsConf !== fontsConf)
        disagree.push(`fontsConf (manifest ${m.fontsConf ?? "unset"} vs exported ${fontsConf})`);
      if (disagree.length)
        problems.push(
          `the environment manifest disagrees with the exported environment on ${disagree.join("; ")}; ` +
            `the recorded id does not describe the inputs that would actually be used`,
        );
    }
  }

  // ── The skew check ───────────────────────────────────────────────────────
  // A browser bundle from one Playwright release driven by another release's
  // npm package is the exact drift tier 1 exists to make impossible, and it
  // fails in the worst possible way: it usually WORKS, and silently changes
  // the pixels.
  const envPw = env.VD0_PLAYWRIGHT_VERSION;
  const resolved = resolvedPlaywrightVersion();
  const pinned = pinnedPlaywrightVersion();
  if (!resolved)
    problems.push("the `playwright` npm package is not installed (run `just capture-setup`)");
  else if (envPw && resolved !== envPw)
    problems.push(
      `playwright skew: the pinned browser bundle is for ${envPw}, the installed npm package is ${resolved}. ` +
        `A hash produced under a skewed pair means nothing — align tools/capture/package.json with the ` +
        `nixpkgs pin in flake.lock.`,
    );
  if (pinned && resolved && pinned !== resolved)
    problems.push(
      `tools/capture/package.json pins playwright ${pinned} but ${resolved} is installed`,
    );

  // ── The browser that would actually launch ───────────────────────────────
  // Everything above is environment bookkeeping; this is the fact. If the
  // executable Playwright resolves is not inside the pinned bundle, none of
  // the pinning happened.
  //
  // AND IT HAS TO EXIST. Playwright derives `executablePath()` from
  // PLAYWRIGHT_BROWSERS_PATH by string construction and never touches the
  // filesystem, so without this line every test below it is a tautology: the
  // path is a store path because PLAYWRIGHT_BROWSERS_PATH was checked to be
  // one, and it is inside the bundle because it was BUILT from the bundle.
  // Asking whether the file is really there is the only part of this block
  // that can fail in a real run — and it is what catches a pinned bundle that
  // does not lay chromium out where this Playwright expects it, which is
  // precisely the risk on a platform the environment has never been built for.
  if (chromiumExecutablePath !== undefined) {
    if (!chromiumExecutablePath)
      problems.push("Playwright could not resolve a Chromium executable");
    else if (!isStorePath(chromiumExecutablePath))
      problems.push(
        `the Chromium that would launch is not in the store: ${chromiumExecutablePath}`,
      );
    else if (browsers && !isInside(browsers, chromiumExecutablePath))
      problems.push(
        `the Chromium that would launch (${chromiumExecutablePath}) is not inside the pinned bundle (${browsers})`,
      );
    else if (!existsAt(chromiumExecutablePath))
      problems.push(
        `the Chromium that would launch does not exist: ${chromiumExecutablePath}. The pinned ` +
          `bundle does not contain the build this Playwright expects, so the browser resolution ` +
          `is a path that was computed rather than found.`,
      );
  }

  return problems;
}

/**
 * @param {object} [o]
 * @param {NodeJS.ProcessEnv} [o.env]
 * @param {string} [o.platform]
 * @param {string|undefined} [o.chromiumExecutablePath] the path Playwright
 *   resolves for chromium. Pass it to get the strongest check; omit it (e.g.
 *   from a tool that never launches a browser) to get the rest.
 * @returns {{
 *   kind: "nix"|"container"|null,
 *   pinned: boolean,
 *   verified: boolean,
 *   tier1Capable: boolean,
 *   id: string|null,
 *   why: string[],
 *   problems: string[],
 *   details: object
 * }}
 */
export function describePinnedEnv({
  env = process.env,
  platform = process.platform,
  arch = process.arch,
  chromiumExecutablePath = undefined,
} = {}) {
  const claimNix = env.VD0_PINNED_ENV === "nix";
  const claimContainer = env.VD0_IN_CONTAINER === "1";

  const base = {
    kind: null,
    pinned: false,
    verified: false,
    tier1Capable: false,
    id: null,
    why: [],
    problems: [],
    details: {
      platform,
      arch,
      node: process.version,
      playwrightResolved: resolvedPlaywrightVersion(),
      playwrightPinned: pinnedPlaywrightVersion(),
      chromiumExecutablePath: chromiumExecutablePath ?? null,
    },
  };

  if (claimNix) {
    const problems = verifyNixClaims(env, chromiumExecutablePath);
    const verified = problems.length === 0;
    const tier1 = verified && TIER1_PLATFORMS.has(platform);
    const why = [];
    if (!verified) why.push("the pinned-environment claim did not verify (see problems)");
    else if (!TIER1_PLATFORMS.has(platform)) why.push(DARWIN_CAVEAT);
    return {
      ...base,
      kind: "nix",
      pinned: verified,
      verified,
      tier1Capable: tier1,
      id: env.VD0_ENV_ID ?? null,
      why,
      problems,
      details: {
        ...base.details,
        envId: env.VD0_ENV_ID ?? null,
        envSystem: env.VD0_ENV_SYSTEM ?? null,
        manifest: env.VD0_ENV_MANIFEST ?? null,
        browsers: env.VD0_BROWSERS_PATH ?? null,
        fontsConf: env.VD0_FONTS_CONF ?? null,
        playwrightPinnedByEnv: env.VD0_PLAYWRIGHT_VERSION ?? null,
        manifestContents: readManifest(env.VD0_ENV_MANIFEST),
      },
    };
  }

  if (claimContainer) {
    // VD.0 originally specified a pinned CONTAINER, and `VD0_IN_CONTAINER=1`
    // was accepted at face value as a tier-1 environment. It is not accepted
    // here, for two reasons and neither of them is that containers are a bad
    // way to pin inputs:
    //
    //   * It is a bare assertion. One exported variable promoted a host run to
    //     a tier-1 pass, with nothing checked. The whole point of tier 1 is
    //     that the inputs are FIXED, and "a variable says so" is not that.
    //   * There is no longer an image behind it. The Dockerfile was retired
    //     when the deliverable was amended to a Nix derivation, and it pinned
    //     a Playwright release the repo no longer pins.
    //
    // Reported as an unverifiable claim rather than ignored, so a caller still
    // exporting it is told why it stopped counting instead of quietly getting
    // an advisory verdict.
    return {
      ...base,
      kind: "container",
      pinned: false,
      verified: false,
      tier1Capable: false,
      id: env.VD0_CONTAINER_DIGEST ?? env.VD0_CONTAINER_IMAGE ?? null,
      why: [],
      problems: [
        "VD0_IN_CONTAINER=1 is set, but the container path was retired when the deliverable " +
          "was amended to a Nix derivation, and an environment claim that cannot be verified is " +
          "not a tier-1 environment. Use `nix run .#capture-env -- …`.",
      ],
      details: {
        ...base.details,
        container: env.VD0_CONTAINER_IMAGE ?? null,
        containerDigest: env.VD0_CONTAINER_DIGEST ?? null,
        containerPlatform: env.VD0_CONTAINER_PLATFORM ?? null,
      },
    };
  }

  return {
    ...base,
    why: [
      "not running in the pinned capture environment; this is a bare host, so the " +
        "browser build, the font set and the compositor are whatever this machine has. " +
        "Run `nix run .#capture-env -- <command>` (or `just capture-canary-pinned`).",
    ],
  };
}

function readManifest(path) {
  if (!path) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** One line for a human, describing where a verdict came from. */
export function summarisePinnedEnv(e) {
  if (e.kind === "nix" && e.tier1Capable) return `pinned (nix ${e.id?.slice(0, 12)})`;
  if (e.kind === "nix" && e.verified) return `pinned (nix ${e.id?.slice(0, 12)}) — but ${process.platform}, ADVISORY`;
  if (e.kind === "nix") return `nix claim UNVERIFIED — ADVISORY`;
  if (e.kind === "container") return `container claim (retired path) — ADVISORY`;
  return "NO — bare host, this verdict is ADVISORY";
}
