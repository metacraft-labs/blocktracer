# CodeTracer icons, vendored

These nine SVGs are **vendored byte-verbatim from CodeTracer**. Nobody here
drew them, and nobody here may edit them: they are the icons the vendored
Stylus component sheets under
`client/src/debugger/vendor/frontend/styles/components/` reference by name, and
the whole point of that vendoring (see `design_system/ct_styl.nim`'s header) is
that BlockTracer *serves CodeTracer's sheets* rather than paraphrasing them.

## Where they came from

| upstream path (`metacraft-labs/codetracer`) | here |
| --- | --- |
| `src/public/resources/origin-icons/clock-rewind.svg` | `origin-icons/clock-rewind.svg` |
| `src/public/resources/origin-icons/door.svg` | `origin-icons/door.svg` |
| `src/public/resources/origin-icons/globe.svg` | `origin-icons/globe.svg` |
| `src/public/resources/origin-icons/hourglass.svg` | `origin-icons/hourglass.svg` |
| `src/public/resources/origin-icons/question.svg` | `origin-icons/question.svg` |
| `src/public/resources/origin-icons/quotation.svg` | `origin-icons/quotation.svg` |
| `src/public/resources/origin-icons/sigma.svg` | `origin-icons/sigma.svg` |
| `src/public/resources/shared/history_value_view_toggle_dark.svg` | `shared/history_value_view_toggle_dark.svg` |
| `src/public/resources/shared/noir_logo_dark_theme.svg` | `shared/noir_logo_dark_theme.svg` |

Copied at CodeTracer commit **`af70456c981ea8e3c8de2534cdee16eca5550efd`** —
the SAME commit `client/src/debugger/vendor/ct_styles.vendor.json` and
`ci/embed-sdk-pin.env`'s `CODETRACER_REF` name, so the sheets and the icons they
reference cannot be from two different upstreams.

The copy was taken off a working checkout whose `HEAD` was
`3e1082a8d5e9ee7cc78ae35902cf446388cfd544`, and all nine files are
**byte-identical at the two commits** (verified by `git cat-file -p
af70456c9:<path> | shasum -a 256` against the working file). That equality is
why a checkout-sourced copy is admissible here at all; a future re-vendor that
cannot reproduce it must take the bytes from the pinned commit.

## WHY THE DIRECTORY LAYOUT IS LOAD-BEARING

`client/src/design_system/ct_styl.nim` REWRITES the `url()`s in the vendored
sheets. Upstream writes them relative to the sheet's own place in CodeTracer's
source tree — `url("../../../public/resources/origin-icons/sigma.svg")` — which
in a BlockTracer publish resolves to `/public/resources/origin-icons/sigma.svg`
and is a 404 for every visitor. That was the measured defect: 9 of the 13
`url()`s in the built `/_a/<hash>.css` were broken, all 9 inside the
`[data-register="debugger"]` scope, i.e. the debugger panels that are the whole
visual-parity goal.

The rewrite maps `…/public/resources/<group>/<file>.svg` onto
`/assets/ct-icons/<group>/<file>.svg`, which is this directory as
`static_export.copyStaticAssets` publishes it. So:

* a file moved out of `<group>/` breaks the build, not the site —
  `ct_components_css.CtVendoredIcons` is the total list, every entry is proved
  present at COMPILE time, and a url with no entry RAISES rather than passing
  through (`ct_styl.nim`'s `rewriteUrls`);
* `tools/deploy/check-assets.mjs` check **A6** then re-asks the question of the
  published bytes: every `url()` in every published stylesheet must resolve to a
  non-empty file in the publish tree.

Adding an icon means adding the file here AND the row in `CtVendoredIcons`.
Removing one that a vendored sheet still references cannot be done quietly.
