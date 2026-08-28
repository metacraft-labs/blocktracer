# The PINNED CAPTURE ENVIRONMENT (VD.0).
#
# Tier 1 of visual-design-iteration.md asks for an exact-hash check, and an
# exact-hash check that runs across heterogeneous runners, GPUs or OS versions
# measures the runner rather than the product. The deliverable is therefore
# FIXED INPUTS, and this derivation fixes the three that decide the pixels:
#
#   1. THE BROWSER BUILD — pkgs.playwright-driver.browsers from the flake's
#      locked nixpkgs. Not a tag, not a download at run time: a store path whose
#      hash covers the Chromium build, and which changes visibly in flake.lock
#      when it moves. The matching npm `playwright` package version is exported
#      as VD0_PLAYWRIGHT_VERSION so the harness can REFUSE a skewed pair rather
#      than hash whatever it happens to find (see lib/pinned-env.mjs).
#
#   2. THE FONTCONFIG SET — an explicit, closed font list (no host fonts reach
#      the browser, because FONTCONFIG_FILE names only these directories) plus
#      the rasterisation rules in fonts-local.conf, INCLUDED rather than copied
#      so the rules stay in the repo, reviewable and diffable. The
#      fontconfig cache is built here, in the store, so it is not rebuilt in a
#      filesystem-order-dependent way on first use.
#
#   3. THE RENDERER FLAGS — defined once in lib/determinism.mjs and applied by
#      capture.mjs on every path. This wrapper records the digest of that file
#      in its manifest, so "the flags changed" is visible in the environment id
#      rather than silently folded into a hash drift.
#
# WHY THIS IS NOT A CONTAINER. It was specified as one and a Dockerfile was
# written, but it needs a daemon that does not run on the development machine,
# and a Linux VM is a heavy dependency for six screenshots. A Nix derivation
# pins the same three things, runs with no daemon on a Linux workstation and in
# CI, and suits a Nix-managed environment. The Docker path was REMOVED rather
# than kept beside this one: it pinned a different Playwright release, so the
# two pinned environments would have disagreed about the browser build, which
# is the exact drift tier 1 exists to prevent. `fonts-local.conf` outlived it
# and is load-bearing here.
#
# THE CAVEAT THIS DERIVATION CANNOT REMOVE. On darwin the pinned Chromium still
# rasterises through the host's CoreGraphics/CoreText stack, which is not a
# pinned input and cannot be made one from inside Nix. So a darwin run of this
# environment is still ADVISORY: the harness refuses to call it a tier-1
# verdict, and darwin<->Linux hashes are not expected to match. The canary only
# requires that ONE environment reproduces itself, and that environment is
# Linux CI. See lib/pinned-env.mjs, which is where the refusal lives.

{ pkgs }:

let
  inherit (pkgs) lib;

  # ── 1. The browser build ─────────────────────────────────────────────────
  # playwright-driver and its browser bundle come as a matched pair from the
  # locked nixpkgs. tools/capture/package.json must pin the SAME npm version;
  # lib/pinned-env.mjs asserts it and fails the environment if it does not.
  playwrightVersion = pkgs.playwright-driver.version;
  browsers = pkgs.playwright-driver.browsers;

  # A pinned Node, so the harness is not run by whatever `node` a host has.
  nodejs = pkgs.nodejs_22;

  # ── 2. The fontconfig set ────────────────────────────────────────────────
  # Deliberately small and explicit. The site serves its own brand faces over
  # @font-face from its own origin (see lib/determinism.mjs), so this set is
  # the FALLBACK stack, and a fallback stack that varies per host is exactly
  # the "measuring the runner" failure tier 1 exists to prevent.
  #
  # DejaVu + Liberation cover Latin/Greek/Cyrillic in sans, serif and mono, and
  # Liberation is metric-compatible with the Arial/Times/Courier names a CSS
  # font stack usually falls through to. Adding families is a change to the
  # pin: it moves the environment id, and every stored hash with it.
  fontPackages = [
    pkgs.dejavu_fonts
    pkgs.liberation_ttf
  ];
  fontDirs = map (p: "${p}/share/fonts") fontPackages;

  # The rasterisation rules. Kept in the repo rather than inlined here so they
  # are reviewable as a fontconfig file; their digest goes into the pin below.
  fontRules = ./fonts-local.conf;

  fontsCache = pkgs.runCommand "vd0-fonts-cache"
    {
      nativeBuildInputs = [ pkgs.fontconfig ];
      # A cache built against a config that names ONLY the pinned dirs, so the
      # cache cannot pick up a host font directory either.
      preferLocalBuild = true;
    }
    ''
      mkdir -p $out
      cat > fonts.conf <<EOF
      <?xml version="1.0"?>
      <fontconfig>
      ${lib.concatMapStringsSep "\n" (d: "  <dir>${d}</dir>") fontDirs}
        <cachedir>$out</cachedir>
      </fontconfig>
      EOF
      FONTCONFIG_FILE=$PWD/fonts.conf fc-cache -f -v > $out/.build-log 2>&1 || true
    '';

  fontsConf = pkgs.writeText "vd0-fonts.conf" ''
    <?xml version="1.0"?>
    <!--
      The pinned capture environment's fontconfig (VD.0).

      Only the directories below are visible to the browser: no <dir>~/.fonts</dir>,
      no /etc/fonts include, no host configuration. The rasterisation rules come
      from tools/capture/fonts-local.conf, INCLUDED rather than duplicated so the
      rules stay reviewable in the repo instead of being inlined here.
    -->
    <fontconfig>
    ${lib.concatMapStringsSep "\n" (d: "  <dir>${d}</dir>") fontDirs}
      <cachedir>${fontsCache}</cachedir>
      <include ignore_missing="no">${fontRules}</include>
    </fontconfig>
  '';

  # ── 3. The renderer flags ────────────────────────────────────────────────
  # Not pinned BY this derivation — they live in the repo, where they belong,
  # because a host run and a pinned run must apply the same ones. What
  # this derivation does is RECORD them, so a flag edit moves the environment
  # id instead of quietly changing every hash under an unchanged id.
  determinismDigest = builtins.hashFile "sha256" ./lib/determinism.mjs;
  fontRulesDigest = builtins.hashFile "sha256" fontRules;

  # ── The environment identity ─────────────────────────────────────────────
  # Everything a hash produced in this environment is conditional on. Two
  # hashes are comparable only if these agree — INCLUDING the system, because
  # amd64 and arm64 Chromium do not rasterise text identically, and darwin does
  # not rasterise like Linux at all.
  pin = {
    schema = "vd0-capture-env/1";
    system = pkgs.stdenv.hostPlatform.system;
    playwright = playwrightVersion;
    browsers = "${browsers}";
    node = nodejs.version;
    nodeStore = "${nodejs}";
    fontsConf = "${fontsConf}";
    fontsCache = "${fontsCache}";
    fonts = map (p: p.name) fontPackages;
    fontRulesSha256 = fontRulesDigest;
    determinismSha256 = determinismDigest;
    fontconfig = pkgs.fontconfig.version;
  };

  # A content hash over the whole pin. Any input moving — a nixpkgs bump, a
  # font added, a renderer flag edited — produces a different id, so a stored
  # baseline can say which environment it came from and a comparison across two
  # different ids is visible as one rather than reported as a regression.
  envId = builtins.hashString "sha256" (builtins.toJSON pin);

  manifest = pkgs.writeText "vd0-capture-env.json"
    (builtins.toJSON (pin // { id = envId; }));

in
pkgs.writeShellApplication {
  name = "vd0-capture-env";
  runtimeInputs = [ nodejs pkgs.fontconfig ];

  # Readable without running anything, so CI (or a reviewer on another system)
  # can ask what a given checkout pins without a build:
  #   nix eval .#capture-env.envId
  #   nix eval --json .#capture-env.pin
  passthru = {
    inherit pin browsers fontsConf fontsCache manifest playwrightVersion;
    envId = envId;
  };

  text = ''
    # Run a command inside the pinned capture environment (VD.0).
    #
    #   vd0-capture-env node tools/capture/check-canary.mjs --no-build
    #   vd0-capture-env --print-pin
    #
    # Everything below is a store path or a value derived from one. Nothing is
    # read from the host, and lib/pinned-env.mjs re-verifies each of these at
    # run time rather than trusting the claim — a VD0_PINNED_ENV=nix that is not
    # actually backed by these paths is downgraded to advisory, not believed.

    if [ "''${1:-}" = "--print-pin" ]; then
      cat ${manifest}
      exit 0
    fi

    # The browser build.
    export PLAYWRIGHT_BROWSERS_PATH=${browsers}
    export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    # The host-requirements probe shells out to ldd/apt and is a host-dependent
    # side effect in an environment whose whole point is not to have any.
    export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true

    # The fontconfig set. FONTCONFIG_FILE replaces the host config outright;
    # the browser sees these directories and nothing else.
    export FONTCONFIG_FILE=${fontsConf}
    export FONTCONFIG_PATH=${pkgs.fontconfig.out}/etc/fonts

    # Locale and timezone reach number formatting, date formatting and
    # occasionally font fallback. Playwright's context sets them too; setting
    # them here as well means the browser PROCESS agrees with the context.
    export TZ=UTC
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8

    # Claimed identity — verified, not trusted, by lib/pinned-env.mjs.
    export VD0_PINNED_ENV=nix
    export VD0_ENV_ID=${envId}
    export VD0_ENV_MANIFEST=${manifest}
    export VD0_ENV_SYSTEM=${pkgs.stdenv.hostPlatform.system}
    export VD0_BROWSERS_PATH=${browsers}
    export VD0_FONTS_CONF=${fontsConf}
    export VD0_PLAYWRIGHT_VERSION=${playwrightVersion}
    export VD0_NODE=${nodejs}/bin/node

    if [ "$#" -eq 0 ]; then
      echo "vd0-capture-env: no command given" >&2
      echo "  vd0-capture-env <command> [args...]" >&2
      echo "  vd0-capture-env --print-pin" >&2
      exit 2
    fi

    exec "$@"
  '';
}
