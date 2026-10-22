## Inline SVG marks — the site's ONE icon convention.
##
## ## Why SVG, and why here
##
## Until this module the explorer drew its only two "icons" in CSS: `.brand .sq`
## is a bordered box with an `::after`, and `.badge.coverage::before` is a
## `border-radius` dot. Those are geometric decorations a rule can describe. A
## brand mark is not — CodeTracer's logo and GitHub's Octocat are specific
## curves, and the alternatives are a remote asset (a request the page must not
## need, and a mark that disappears when the asset does), a font glyph (♥ and
## ⏭ render as a dingbat on one platform and a colour emoji on another, which
## is exactly the per-platform drift a graded capture matrix must not carry),
## or an approximation drawn by hand, which is not the mark.
##
## So: inline SVG, built through the isonim DSL rather than spliced through
## `raw`. That is not a style preference — `tools/design/check-tokens.mjs` A7
## rejects a hand-built fragment, because markup the DSL never sees is markup
## no rule above it can inspect. Every attribute below is a DSL keyword
## argument for the same reason every colour is a token.
##
## The debugger's stepping toolbar USED to be the exception, and the paragraph
## that stood here defended it: the eight `.dcglyph` marks were text glyphs
## because they were "the vendored controls model's own data, this module has
## no say in them, and re-drawing eight of them here would fork a thing the
## Embed SDK owns."
##
## **Every clause of that was wrong, and it cost the exact defect this file's
## opening paragraph predicts.** `ControlButton.glyph` was declared in
## `client/src/debugger/session_view.nim` — BlockTracer's own module, not the
## vendored subtree beside it — was written by two of BlockTracer's own
## producers (`hydrate/session_project.nim`, `debugger/demo_session.nim`, which
## carried duplicate copies of the table), and was read by exactly one consumer
## in this repository. It crossed no Embed SDK boundary; `just sdk-boundary`
## scans for it and finds nothing. There was no fork to avoid.
##
## What the exemption actually bought was a toolbar whose Continue button was
## `⏭` U+23ED — the media transport "next track / skip to end" mark, which is
## the glyph named four paragraphs above as the reason this module exists. A
## user reported it as "the standard icon of music/video players for 'rewind to
## the end of the episode'", which is not an impression but an identification:
## U+23ED and U+23EE ALSO carry `Emoji_Presentation=Yes`, so on macOS, iOS and
## Android those two buttons rendered as COLOUR EMOJI while their six
## neighbours rendered as monochrome text — the per-platform drift this module
## was created to end, on the one control strip it had exempted from itself.
##
## So the toolbar's marks are here now, and `ControlButton` carries an action
## rather than a glyph. `Debugger-Controls.md` §"Control Actions" holds the
## reason for each one.
##
## ## The rules every mark below follows
##
## * `fill="currentColor"`. A mark inherits the colour of the text it sits in,
##   so it is themed by the token layer that themes that text and there is no
##   colour literal anywhere in this file. The source assets' own fills
##   (`#F3F3F3` on CodeTracer's, an implicit black on GitHub's) are dropped for
##   that reason and not by accident: a hex here would fail A1, and a mark that
##   is light-grey in both themes is a mark that vanishes in one of them.
## * `aria-hidden="true"` and `focusable="false"` — for every mark that sits
##   INSIDE a link or a button that already carries its own accessible name,
##   which is all of them but one. A second name on the same control is a
##   control announced twice. `focusable` is IE/Edge-legacy but costs one
##   attribute and keeps the SVG out of the tab order where it is honoured.
##   The heart is the exception and says why at its own definition.
## * No `width`/`height` attributes. The size is a design value and design
##   values live in `web.tokens.json`; the callers' stylesheets size these with
##   `var(--bt-*)`. Attributes here would be A2 raw lengths AND a second place
##   to change a size.

import isonim/ssr/escape
import isonim/dsl/ui

const CodeTracerMarkPath = "M9.95469 2.47618H6.44126V0L-2.86102e-05 6.14776H9." &
  "95469C13.3408 6.14776 16.1032 8.79472 16.1032 12.0394V12.5395H19.9349V12.0" &
  "394C19.9349 6.76986 15.4667 2.47618 9.95469 2.47618ZM20.0018 14.1116H10.04" &
  "71C6.66098 14.1116 3.89861 11.4646 3.89861 8.21998V7.71986H0.0669384V8.219" &
  "98C0.0669384 13.4895 4.54783 17.7832 10.0471 17.7832H13.5605V20.2593L20.00" &
  "18 14.1116ZM12.6077 10.0946C12.6077 11.5067 11.4171 12.6516 9.94845 12.651" &
  "6C8.4798 12.6516 7.28922 11.5067 7.28922 10.0946C7.28922 8.68237 8.4798 7." &
  "53756 9.94845 7.53756C11.4171 7.53756 12.6077 8.68237 12.6077 10.0946Z"
  ## CodeTracer's mark, byte-for-byte the `d` of `codetracer/icon.svg` — the
  ## application icon on the `dev` mainline, which is also `menu/ct_logo_dark.svg`
  ## (the two files are identical). It is the real mark and not a redrawing of
  ## one: the two arcs and the centre dot are a single `Union` path, so there is
  ## nothing here to get subtly wrong.
  ##
  ## Split across `&` only to keep the source inside a sane line length. The
  ## token checker re-reads `&`-joined runs AS ONE STRING for exactly the
  ## opposite case (a colour hidden across a concatenation), so the split
  ## conceals nothing from it.

const GithubMarkPath = "M165.9,397.4c0,2-2.3,3.6-5.2,3.6-3.3.3-5.6-1.3-5.6-3.6" &
  ",0-2,2.3-3.6,5.2-3.6C163.3,393.5,165.9,395.1,165.9,397.4Zm-31.1-4.5c-.7,2," &
  "1.3,4.3,4.3,4.9,2.6,1,5.6,0,6.2-2s-1.3-4.3-4.3-5.2c-2.6-.7-5.5.3-6.2,2.3Zm" &
  "44.2-1.7c-2.9.7-4.9,2.6-4.6,4.9.3,2,2.9,3.3,5.9,2.6,2.9-.7,4.9-2.6,4.6-4.6" &
  "C184.6,392.2,181.9,390.9,179,391.2ZM244.8,8C106.1,8,0,113.3,0,252,0,362.9," &
  "69.8,457.8,169.5,491.2c12.8,2.3,17.3-5.6,17.3-12.1,0-6.2-.3-40.4-.3-61.4,0" &
  ",0-70,15-84.7-29.8,0,0-11.4-29.1-27.8-36.6,0,0-22.9-15.7,1.6-15.4,0,0,24.9" &
  ",2,38.6,25.8,21.9,38.6,58.6,27.5,72.9,20.9,2.3-16,8.8-27.1,16-33.7-55.9-6." &
  "2-112.3-14.3-112.3-110.5,0-27.5,7.6-41.3,23.6-58.9-2.6-6.5-11.1-33.3,2.6-6" &
  "7.9,20.9-6.5,69,27,69,27a236.241,236.241,0,0,1,125.6,0s48.1-33.6,69-27c13." &
  "7,34.7,5.2,61.4,2.6,67.9,16,17.7,25.8,31.5,25.8,58.9,0,96.5-58.9,104.2-114" &
  ".8,110.5,9.2,7.9,17,22.9,17,46.4,0,33.7-.3,75.4-.3,83.6,0,6.5,4.6,14.4,17." &
  "3,12.1C428.2,457.8,496,362.9,496,252,496,113.3,383.5,8,244.8,8ZM97.2,352.9" &
  "c-1.3,1-1,3.3.7,5.2,1.6,1.6,3.9,2.3,5.2,1,1.3-1,1-3.3-.7-5.2C100.8,352.3," &
  "98.5,351.6,97.2,352.9Zm-10.8-8.1c-.7,1.3.3,2.9,2.3,3.9,1.6,1,3.6.7,4.3-.7." &
  "7-1.3-.3-2.9-2.3-3.9C88.7,343.5,87.1,343.8,86.4,344.8Zm32.4,35.6c-1.6,1.3-" &
  "1,4.3,1.3,6.2,2.3,2.3,5.2,2.6,6.5,1,1.3-1.3.7-4.3-1.3-6.2C123.1,379.1,120." &
  "1,378.8,118.8,380.4Zm-11.4-14.7c-1.6,1-1.6,3.6,0,5.9s4.3,3.3,5.6,2.3c1.6-1" &
  ".3,1.6-3.9,0-6.2-1.4-2.3-4-3.3-5.6-2Z"
  ## GitHub's Octocat mark, the `d` of `codetracer/docs/book-isonim/static/img/
  ## icon__github.svg` — a real asset already shipped by a sibling site in this
  ## organisation, not a redrawing. Its `translate(0,-8)` is folded into the
  ## viewBox below instead of being carried as a transform.

const HeartPath = "M8 1.314C12.438-3.248 23.534 4.735 8 15-7.534 4.736 3.562" &
  "-3.248 8 1.314Z"
  ## A heart, and the one mark here that is not somebody's logo — there is no
  ## "official" heart to find, and a symbol in a credit line is not a brand.
  ## Drawn as two symmetric cubics from the Bootstrap Icons `heart-fill`
  ## geometry (MIT) so the two lobes actually match, which is the part a
  ## hand-drawn heart gets wrong.
  ##
  ## It is a mark and not the character ♥ for the reason at the top of this
  ## file: U+2665 picks up a colour emoji presentation on several platforms and
  ## a text presentation on others, and this line is photographed in four
  ## viewports and two themes.

const SharePath = "M11 2.5a2.5 2.5 0 1 1 .603 1.628l-6.718 3.12a2.5 2.5 0 0 1" &
  " 0 1.504l6.718 3.12a2.5 2.5 0 1 1-.488.876l-6.718-3.12a2.5 2.5 0 1 1 0-3.2" &
  "56l6.718-3.12A2.5 2.5 0 0 1 11 2.5Z"
  ## The share node (Bootstrap Icons `share-fill`, MIT). Three dots and two
  ## edges — the shape a reader already reads as "send this elsewhere".

const DownloadPath = "M.5 9.9a.5.5 0 0 1 .5.5v2.5a1 1 0 0 0 1 1h12a1 1 0 0 0 " &
  "1-1v-2.5a.5.5 0 0 1 1 0v2.5a2 2 0 0 1-2 2H2a2 2 0 0 1-2-2v-2.5a.5.5 0 0 1 " &
  ".5-.5ZM7.646 11.854a.5.5 0 0 0 .708 0l3-3a.5.5 0 0 0-.708-.708L8.5 10.293V" &
  "1.5a.5.5 0 0 0-1 0v8.793L5.354 8.146a.5.5 0 1 0-.708.708l3 3Z"
  ## Arrow into a tray (Bootstrap Icons `download`, MIT).

# ── The debugger's eight stepping marks ────────────────────────────────────
#
# Four are VS Code codicons, `d` verbatim (microsoft/vscode-codicons, CC BY 4.0
# — https://github.com/microsoft/vscode-codicons, LICENSE). Four are drawn here
# because NO PRODUCT ANYWHERE SHIPS THEM. The survey and the reasoning are in
# `Debugger-Controls.md` §"Control Actions"; what follows is the short form,
# because a later reader will otherwise re-litigate the drawn four.
#
# ## The rule the whole family obeys
#
# A reverse control is its forward partner REFLECTED ABOUT THE VERTICAL AXIS.
# That is Microsoft's own stated rule for the two reverse controls VS Code has
# (microsoft/vscode#85111: "Step back should have the icon that is step over
# rotated for 180 degrees" — the issue says rotated, the art that shipped is a
# reflection, and the dot staying at the BOTTOM in both `debug-step-over` and
# `debug-step-back` proves which one it is). Mozilla's WebReplay implemented
# the identical rule as one CSS declaration, `transform: scaleX(-1)` on
# `stepOver.svg`.
#
# ## Why four had to be drawn
#
# `debug-step-into` and `debug-step-out` are a VERTICAL arrow over a CENTRED
# dot, and they are therefore mirror-symmetric about x=8: under `x → 16-x`,
# 12.03↔3.968, 10.969↔5.029, 8.749↔7.249. Reflecting one is a LITERAL NO-OP —
# the mirrored file is the same picture — so the family's own rule cannot
# express "reverse step in". The same is true of every product surveyed:
# JetBrains, Xcode, Visual Studio, Chrome DevTools and Eclipse all draw step
# in/out as a strictly vertical arrow over a centred marker.
#
# Nobody has solved it. DAP defines only `stepBack` and `reverseContinue`, so
# the gap propagates to every VS Code-derived debugger; Firefox WebReplay and
# Replay.io shipped no reverse step in/out at all; gdbgui replaced direction
# with a checkbox labelled "reverse"; and Midas, an rr front-end that does ship
# a reverse-finish, contributes `"icon": "$(debug-step-out)"` — THE FORWARD
# GLYPH VERBATIM, so an rr session shows the same mark twice side by side and
# the tooltip is the only difference. That last one is precisely what a naive
# "just mirror everything" produces here, and it is the outcome these four
# exist to avoid.
#
# ## What the drawn four do about it
#
# They put the step in/out arrow on a DIAGONAL, which is the smallest change
# that gives the glyph a left-right handedness for the family's rule to act on.
# Two channels, orthogonal, and neither invented — both are already load-bearing
# in the codicons beside them:
#
#   VERTICAL   — where the arrowhead points. Down, at the dot, is "into"; up,
#                away from it, is "out of". Unchanged from every product above.
#   HORIZONTAL — which half the arrowhead sits in. Right is forward, left is
#                reverse. This is exactly what separates `debug-step-over`
#                (arrowhead top-right) from `debug-step-back` (top-left), and
#                `debug-continue` (apex x=14.6) from `debug-reverse-continue`
#                (apex x=1.4).
#
# So the four occupy the four diagonal quadrants around the shared dot, each is
# its partner's exact reflection, and the two rules a reader has to learn are
# the two the four codicons beside them already teach.
#
# The dot is Microsoft's "modifier badge" (vscode-codicons#389), lifted from
# `debug-step-over` so that all eight marks share one anchor.

const DebugBadgePath = "M10 13C10 14.103 9.103 15 8 15C6.897 15 6 14.103 6 " &
  "13C6 11.897 6.897 11 8 11C9.103 11 10 11.897 10 13Z"
  ## The filled dot at (8,13) r=2 — the current statement. Byte-identical to
  ## the circle subpath of `debug-step-over.svg`, so the drawn marks and the
  ## vendored ones cannot drift apart at the one element they share.

# ── THE TOOLBAR'S EIGHT MARKS LEFT THIS FILE ──────────────────────────────
#
# `ContinuePath` and its seven siblings, `filledMark`, `badgedMark` and the
# eight `*Mark` procs were here: hand-drawn SVG for the debugger toolbar, in a
# product whose claim is that its debugger looks like CodeTracer's. They were
# close to upstream's and they were not upstream's, and nothing propagated
# when a glyph changed there.
#
# They are now `vendor/frontend/viewmodel/views/debug_control_marks`, vendored
# byte-verbatim at the embed-SDK pin, rendered through
# `components/debugger.controlMark`, and sized by the `.ct-control-mark` rule
# the vendored `button.styl` already carried and nothing used. See that proc,
# and `ci/test/control-marks-vendor.sh`.
#
# `DebugBadgePath` above stays: it is the filled dot the OTHER marks in this
# file share, and its comment records that it is byte-identical to the circle
# subpath of `debug-step-over.svg` so the drawn and vendored marks cannot
# drift at the one element they share.


const SettingsPath = "M9.405 1.05c-.413-1.4-2.397-1.4-2.81 0l-.1.34a1.464 " &
  "1.464 0 0 1-2.105.872l-.31-.17c-1.283-.698-2.686.705-1.987 1.987l.169" &
  ".311c.446.82.023 1.841-.872 2.105l-.34.1c-1.4.413-1.4 2.397 0 2.81l.34" &
  ".1a1.464 1.464 0 0 1 .872 2.105l-.17.31c-.698 1.283.705 2.686 1.987 " &
  "1.987l.311-.169a1.464 1.464 0 0 1 2.105.872l.1.34c.413 1.4 2.397 1.4 " &
  "2.81 0l.1-.34a1.464 1.464 0 0 1 2.105-.872l.31.17c1.283.698 2.686-.705 " &
  "1.987-1.987l-.169-.311a1.464 1.464 0 0 1 .872-2.105l.34-.1c1.4-.413 " &
  "1.4-2.397 0-2.81l-.34-.1a1.464 1.464 0 0 1-.872-2.105l.17-.31c.698-" &
  "1.283-.705-2.686-1.987-1.987l-.311.169a1.464 1.464 0 0 1-2.105-.872l-" &
  ".1-.34zM8 10.93a2.929 2.929 0 1 1 0-5.86 2.929 2.929 0 0 1 0 5.858z"
  ## Bootstrap Icons `gear-fill` (MIT), which is already authored on the 16×16
  ## box these marks use, so it needs none of `githubMark`'s viewBox folding.
  ##
  ## A DRAWN MARK AND NOT A DINGBAT, for the reason this file's header records
  ## at length: the toolbar's `⏭`/`⏮` were `Emoji_Presentation=Yes` codepoints
  ## and rendered as COLOUR EMOJI beside six monochrome neighbours on macOS,
  ## iOS and Android. `⚙` (U+2699) has exactly that property and would
  ## reproduce it in the identity bar, next to Share and Download, which are
  ## already drawn paths.
  ##
  ## The inner circle is a second subpath wound the other way, so the gear's
  ## hole is a hole under the default fill rule and needs no `fill-rule`
  ## attribute.

proc settingsMark*(cls = "svgicon"): string =
  ## The gear, for the shortcuts dialog's opener in `.dbgacts`.
  ##
  ## `aria-hidden`, like every other mark here: the button that carries it has
  ## an `aria-label` already, and a mark that announced itself would be a
  ## control named twice.
  ui:
    svg(class = cls, viewBox = "0 0 16 16", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(d = SettingsPath)

proc codeTracerMark*(cls = "svgicon"): string =
  ## CodeTracer's mark, at the size the caller's class gives it.
  ui:
    svg(class = cls, viewBox = "0 0 20 21", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(`fill-rule` = "evenodd", `clip-rule` = "evenodd",
           d = CodeTracerMarkPath)

proc githubMark*(cls = "svgicon"): string =
  ## GitHub's mark. The source asset offsets its path by -8 in y and states a
  ## 0-based viewBox; the offset is folded into the viewBox's origin here, so
  ## the element carries no transform and scales from its own box.
  ui:
    svg(class = cls, viewBox = "0 8 496 483.607", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(d = GithubMarkPath)

proc heartMark*(label: string; cls = "svgicon heart"): string =
  ## The heart in the credit line — the ONE labelled mark in this module.
  ##
  ## It is not inside a link and it is not decoration beside a word that
  ## already says what it means: it IS a word. "Built with ♥ by Metacraft Labs"
  ## read with the mark hidden is "Built with by Metacraft Labs", a sentence
  ## with a hole in it. So it takes `role="img"` and the word as its accessible
  ## name, and the announced sentence is the written one.
  ##
  ## The label is a parameter rather than a constant here because the sentence
  ## it completes is the caller's, and a mark that hard-coded its own English
  ## would be a second place the credit line is written.
  ui:
    svg(class = cls, viewBox = "0 0 16 16", fill = "currentColor",
        role = "img", `aria-label` = label, focusable = "false"):
      path(d = HeartPath)

proc shareMark*(cls = "svgicon"): string =
  ## The share node, for the identity bar's Share action.
  ui:
    svg(class = cls, viewBox = "0 0 16 16", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(d = SharePath)

proc downloadMark*(cls = "svgicon"): string =
  ## The download arrow, for the identity bar's trace download.
  ui:
    svg(class = cls, viewBox = "0 0 16 16", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(d = DownloadPath)
