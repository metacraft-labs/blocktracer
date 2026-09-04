## Site footer — a single honest line about what this build is (a demo-data
## render), the standing product credo, and the provenance strip: who built
## this, what it is built on, and where the source is.
##
## ## Why the provenance strip is HERE and not in the nav
##
## The GitHub mark is in this footer and NOT in `nav.nim`, and it is in exactly
## one of the two. The nav is a fixed bar carrying the site's own destinations
## and the search field — it answers "where in BlockTracer do I go next", and
## every item in it is a place inside this site. "Where is the source" is not a
## destination inside the site; it is a fact ABOUT the site, in the same class
## as who built it and what it is built on. The footer already holds that class
## of statement ("Rendered from demo data … no live chain, no account, no
## tracking"), so the repository link joins the sentence that names Metacraft
## Labs and CodeTracer rather than displacing a navigation target from a bar
## that is pinned to every viewport at every scroll position.
##
## ## Why the transaction page does not get this
##
## Because it never calls this procedure. `layout.pageLayout` renders the nav,
## the body and this footer; `layout.debugLayout` renders the content and
## nothing else, and §7.0 sends every transaction with a published trace to
## `debugLayout`. The exclusion is therefore a property of WHICH SHELL a route
## chose — a full-viewport debugging session and a browsable explorer page are
## two shells, and they always were — and not a conditional inside one shell
## that a later edit could get the wrong way round. Nothing in this file knows
## the debug route exists, which is the point.

import isonim/ssr/escape
import isonim/dsl/ui
import ./icons

const
  MetacraftUrl = "https://metacraft-labs.com"
  CodeTracerUrl* = "https://codetracer.com"
    ## Exported because `pages/about` names CodeTracer in its opening
    ## paragraph and links it there too. One address, one spelling: a product
    ## name written as a literal in a second file is a second thing to update
    ## when it moves, and the two would not fail together.
  SourceUrl = "https://github.com/metacraft-labs/blocktracer"
    ## `metacraft-labs/blocktracer` — THIS repository, verified public before
    ## it was linked (`gh repo view --json visibility` → PUBLIC). The claim the
    ## strip makes is that this explorer is open source, so the link has to be
    ## the explorer's own tree; pointing it at CodeTracer's would be a true
    ## statement about a different program. CodeTracer's repository is public
    ## too, and it is reachable one click on from the CodeTracer link beside it.

proc siteFooter*(): string =
  ui:
    footer(class = "foot"):
      tdiv(class = "inner"):
        tdiv:
          text "BlockTracer — the deepest view into every transaction."
          # THE THIRD LINK IS BACK, AND IT IS NOT THE ONE THAT LEFT.
          #
          # `Privacy & settings` went when the prose page behind it was removed,
          # and it could not have been repointed anywhere: the label promised
          # two destinations and neither survived as one. `/settings` now serves
          # a DIFFERENT page — a keymap preset chooser and the full list of
          # bound chords — so this is a new link to a new page that happens to
          # share a route, not the restoration of the old one.
          #
          # THE LABEL IS THE PAGE'S NAME AND NOT THE ROUTE'S, which is the rule
          # `viewutil.settingsUrl` states and the reason the old label was
          # wrong. The route is `/settings` and the page is titled
          # `Keyboard shortcuts`; a footer reading `Settings` would promise a
          # preferences surface in general and deliver one setting, which is the
          # same over-promise in a shorter word. It is the full two words rather
          # than `Shortcuts`, because a bare `Shortcuts` in a footer beside
          # `About` and `Chains` reads as shortcuts to places on the site.
          #
          # A LITERAL, matching its two siblings, and NOT `viewutil.settingsUrl`.
          # Calling it would be the tidier-looking choice and is the wrong one
          # here: `viewutil` imports `reader`, `session_view` and
          # `components/provenance`, so a component would be reaching up a layer
          # and dragging the data seam behind it to obtain one string. `/about`
          # and `/chains` are literals in this file for the same reason. The
          # rule `settingsUrl` documents is about the LABEL, and that rule is
          # followed above; the route spelling is three characters and shared
          # with nothing that can drift independently of the router.
          tdiv(class = "footlinks"):
            a(href = "/about"): text "About"
            a(href = "/chains"): text "Chains"
            a(href = "/settings"): text "Keyboard shortcuts"
        tdiv(class = "footcredit"):
          p(class = "credo"):
            # The heart carries the word it stands for as its accessible name,
            # so the announced sentence is the written one. It is the only mark
            # on this page that is a WORD rather than a decoration beside one —
            # see `icons.heartMark`.
            text "Built with "
            raw heartMark("love")
            text " by "
            a(href = MetacraftUrl): text "Metacraft Labs"
            text ". Powered by "
            a(class = "ctcredit", href = CodeTracerUrl):
              text "CodeTracer"
              raw codeTracerMark("svgicon ct")
          # `rel="noopener"` and nothing else. There is no `target="_blank"`:
          # opening a new tab is a decision that belongs to the reader's own
          # gesture, and this site has no script that could restore the one
          # thing a new tab would have preserved.
          a(class = "repolink", href = SourceUrl, rel = "noopener"):
            raw githubMark()
            text "Source on GitHub"
        # THE FOOTER CARRIES NO DISCLOSURE LINE AT ALL, AND THAT IS THE END
        # OF A THREE-STEP RETREAT WORTH RECORDING, BECAUSE EACH STEP LOOKED
        # LIKE THE ANSWER.
        #
        # 1. It said "rendered from demo data", unconditionally. True while the
        #    tree published one synthetic chain; false once it published three,
        #    and false in the dangerous direction — it sat in the footer of all
        #    819 pages, including the 632 whose marker directly above it reads
        #    "Real Aztec mainnet data", telling readers real chain data was a
        #    demo.
        #
        # 2. So it stopped asserting and started POINTING: "Each chain states on
        #    its own pages whether its data is synthetic (`blocktracer-demo-gen`)
        #    or captured from a network." A reader reported that as copy written
        #    for the development team, and it was — a navigational instruction
        #    about where information lives, naming a build tool by its package
        #    name, in a footer.
        #
        # 3. That left "No account, no tracking." — short, true, and not
        #    engineering prose, which is exactly why it survived the sweep that
        #    removed the rest. The same reader asked for it too, and they were
        #    right. It passed every filter being applied and still failed the
        #    only test that matters: it answers a question nobody asked. A block
        #    explorer that REQUIRED an account would have to say so; one that
        #    does not has nothing to announce. Reassurance about a doubt the
        #    reader does not have is the same fault as a build-process
        #    guarantee, wearing a shorter sentence — and the shortness is what
        #    hid it.
        #
        # Nothing replaces it. The claims are still made, in the one place a
        # reader goes looking for them: `/settings` answers what this site can
        # see, `/about` itemises it, and both are linked from the row directly
        # above. The footer is not empty either — it still carries the product
        # line, the three links, the credit and the source link. There was no
        # hole to fill, which is why no filler was written.
