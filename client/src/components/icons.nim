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

const ContinuePath = "M14.578 7.149L7.578 2.186C7.397 2.058 7.198 2 7.003 2C6" &
  ".484 2 6 2.411 6 3.002V13.003C6 13.594 6.485 14.005 7.004 14.005C7.201 14." &
  "005 7.403 13.946 7.585 13.815L14.585 8.777C15.142 8.376 15.139 7.546 14.57" &
  "9 7.15L14.578 7.149ZM7.5 12.027V3.969L13.14 7.968L7.5 12.027ZM3.5 2.75V13." &
  "25C3.5 13.664 3.164 14 2.75 14C2.336 14 2 13.664 2 13.25V2.75C2 2.336 2.33" &
  "6 2 2.75 2C3.164 2 3.5 2.336 3.5 2.75Z"
  ## `debug-continue.svg`, verbatim: a bar at x 2–3.5 and an outlined triangle
  ## with its apex at x=14.6.
  ##
  ## THE BAR IS AT THE TAIL — behind the direction of travel, marking where
  ## execution is stopped — and that is the entire difference between this mark
  ## and the media transport glyph the toolbar used to carry. `⏭` U+23ED puts
  ## its bar at the HEAD, in front of the triangle, at the end you skip TO.
  ## Same two elements, opposite arrangement, opposite meaning. Six of the seven
  ## products surveyed draw Continue exactly this way (Visual Studio is the one
  ## exception, a bare triangle); not one of them, in any command, puts the bar
  ## at the head.

const ReverseContinuePath = "M8.99688 2C8.80188 2 8.60288 2.058 8.42188 2.186" &
  "L1.42188 7.149C0.861882 7.546 0.858882 8.376 1.41588 8.776L8.41588 13.814C" &
  "8.59788 13.945 8.79988 14.004 8.99688 14.004C9.51588 14.004 10.0009 13.593" &
  " 10.0009 13.002V3.002C10.0009 2.412 9.51688 2 8.99788 2H8.99688ZM8.49988 1" &
  "2.027L2.85988 7.968L8.49988 3.969V12.027ZM13.9999 2.75V13.25C13.9999 13.66" &
  "4 13.6639 14 13.2499 14C12.8359 14 12.4999 13.664 12.4999 13.25V2.75C12.49" &
  "99 2.336 12.8359 2 13.2499 2C13.6639 2 13.9999 2.336 13.9999 2.75Z"
  ## `debug-reverse-continue.svg`, verbatim — `ContinuePath` reflected, bar
  ## still at the tail (now the right). Added to the codicon set in commit
  ## 1ee703d9 to close microsoft/vscode#85111, whose bug was that VS Code had
  ## been shipping a FORWARD-pointing triangle on its reverse-continue button
  ## because no reverse glyph existed. Improvising a reverse mark from an
  ## incomplete set is a documented way to ship a control pointing the wrong
  ## way, which is why these four are vendored rather than approximated.

const StepOverPath = "M9.99993 13C9.99993 14.103 9.10293 15 7.99993 15C6.8969" &
  "3 15 5.99993 14.103 5.99993 13C5.99993 11.897 6.89693 11 7.99993 11C9.1029" &
  "3 11 9.99993 11.897 9.99993 13ZM13.2499 2C12.8359 2 12.4999 2.336 12.4999 " &
  "2.75V4.027C11.3829 2.759 9.75993 2 7.99993 2C5.03293 2 2.47993 4.211 2.060" &
  "93 7.144C2.00193 7.554 2.28793 7.934 2.69793 7.993C2.73393 7.999 2.76993 8" &
  ".001 2.80493 8.001C3.17193 8.001 3.49293 7.731 3.54693 7.357C3.86093 5.159" &
  " 5.77593 3.501 8.00093 3.501C9.52993 3.501 10.9199 4.264 11.7439 5.501H9.7" &
  "5093C9.33693 5.501 9.00093 5.837 9.00093 6.251C9.00093 6.665 9.33693 7.001" &
  " 9.75093 7.001H13.2509C13.6649 7.001 14.0009 6.665 14.0009 6.251V2.751C14." &
  "0009 2.337 13.6649 2.001 13.2509 2.001L13.2499 2Z"
  ## `debug-step-over.svg`, verbatim: the badge, and an arc that hops OVER it
  ## and lands in a right-angle arrowhead at the top RIGHT. The badge is
  ## included in this path — it is one `d` in the source file.

const ReverseStepOverPath = "M8 11C6.897 11 6 11.897 6 13C6 14.103 6.897 15 8" &
  " 15C9.103 15 10 14.103 10 13C10 11.897 9.103 11 8 11ZM13.939 7.144C13.52 4" &
  ".211 10.966 2 8 2C6.24 2 4.617 2.758 3.5 4.027V2.75C3.5 2.336 3.164 2 2.75" &
  " 2C2.336 2 2 2.336 2 2.75V6.25C2 6.664 2.336 7 2.75 7H6.25C6.664 7 7 6.664" &
  " 7 6.25C7 5.836 6.664 5.5 6.25 5.5H4.257C5.081 4.263 6.471 3.5 8 3.5C10.22" &
  "5 3.5 12.14 5.158 12.454 7.356C12.508 7.73 12.829 8 13.196 8C13.231 8 13.2" &
  "67 7.998 13.303 7.992C13.713 7.933 13.998 7.554 13.94 7.143L13.939 7.144Z"
  ## `debug-step-back.svg`, verbatim — `StepOverPath` reflected, arrowhead now
  ## at the top LEFT, badge still at the bottom centre.

# The drawn four. Each is one open polyline — shaft, then the two legs of the
# arrowhead — stroked rather than filled, at the codicon's own 1.5-ish weight.
# Each `Reverse*` constant is its partner under `x → 16-x`, arithmetic that a
# reader can check by hand, which is the point of writing them out rather than
# emitting a `transform`: a `scaleX(-1)` would also mirror the badge, and the
# badge is the one element that must NOT move.

const StepInPath = "M4.6 3.6L10.4 9.4M10.4 6.2L10.4 9.4L7.2 9.4"
  ## Down-and-right into the badge: arrowhead in the RIGHT half (forward),
  ## pointing DOWN at the dot (into the callee).

const ReverseStepInPath = "M11.4 3.6L5.6 9.4M5.6 6.2L5.6 9.4L8.8 9.4"
  ## `StepInPath` reflected: 4.6↔11.4, 10.4↔5.6, 7.2↔8.8.

const StepOutPath = "M5.6 9.4L11.4 3.6M8.2 3.6L11.4 3.6L11.4 6.8"
  ## Up-and-right away from the badge: arrowhead in the RIGHT half (forward),
  ## pointing UP and away (out of the callee).

const ReverseStepOutPath = "M10.4 9.4L4.6 3.6M7.8 3.6L4.6 3.6L4.6 6.8"
  ## `StepOutPath` reflected: 5.6↔10.4, 11.4↔4.6, 8.2↔7.8.

proc filledMark(cls, d: string): string =
  ## A vendored codicon: one filled path, the badge included in its own `d`.
  ui:
    svg(class = cls, viewBox = "0 0 16 16", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(d = d)

proc badgedMark(cls, d: string): string =
  ## One of the drawn four: the shared badge, then the stroked arrow.
  ##
  ## `stroke-width` is a number and not a token because it is in USER UNITS of
  ## a 16-unit viewBox, not a CSS length — it scales with the mark, and a
  ## `--bt-*` value here would be a px quantity applied inside a coordinate
  ## system that has none. It is also why these carry no `width`/`height`, for
  ## the reason at the top of this file.
  ui:
    svg(class = cls, viewBox = "0 0 16 16", fill = "currentColor",
        `aria-hidden` = "true", focusable = "false"):
      path(d = DebugBadgePath)
      path(d = d, fill = "none", stroke = "currentColor",
           `stroke-width` = "1.6", `stroke-linecap` = "round",
           `stroke-linejoin` = "round")

proc continueMark*(cls = "svgicon dcmark"): string = filledMark(cls, ContinuePath)
proc reverseContinueMark*(cls = "svgicon dcmark"): string =
  filledMark(cls, ReverseContinuePath)
proc stepOverMark*(cls = "svgicon dcmark"): string = filledMark(cls, StepOverPath)
proc reverseStepOverMark*(cls = "svgicon dcmark"): string =
  filledMark(cls, ReverseStepOverPath)
proc stepInMark*(cls = "svgicon dcmark"): string = badgedMark(cls, StepInPath)
proc reverseStepInMark*(cls = "svgicon dcmark"): string =
  badgedMark(cls, ReverseStepInPath)
proc stepOutMark*(cls = "svgicon dcmark"): string = badgedMark(cls, StepOutPath)
proc reverseStepOutMark*(cls = "svgicon dcmark"): string =
  badgedMark(cls, ReverseStepOutPath)

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
