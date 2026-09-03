## Settings (`/settings`) — Page-Descriptions §12.
##
## "Entirely client-side; nothing leaves the browser." Four groups: storage,
## debugger, privacy, advanced.
##
## ## Why there is not one control on this page
##
## §12's four groups are all *browser* state — a local cache ceiling, a theme, a
## keybinding set, a registry override. Reading or writing any of them needs
## script, and this client ships none. §13 already settled what to do about
## that, for the copy button: "a copy *button* there would be a control that
## cannot succeed — which this product does not ship."
##
## A settings page of controls that silently do nothing is the same defect with
## more surface area, and it is worse here than elsewhere, because a settings
## control that appears to accept a value has told the user their preference was
## recorded. So each group states what it will control, and where it can, states
## the **current** answer — which for the whole privacy group is a fact about
## this deployment and needs no script at all.
##
## The privacy group is therefore not a placeholder: it is the only page in the
## product that answers "what can this deployment observe about me", and the
## answer is complete today.

import isonim/ssr/escape
import isonim/dsl/ui
import ../viewutil

proc settingsPage*(): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          span: text "settings"
        tdiv(class = "eyebrow"): text "Preferences"
        h1(class = "h1"): text "Settings"
        p(class = "lead"):
          # "…and there is nothing about data sources to configure — a visitor
          # chooses nothing that affects where a byte comes from" went. It
          # answers "why can't I configure the data source?", which is a
          # question about the architecture that no visitor arrives holding.
          text "Everything here is browser state. Nothing on this page is "
          text "sent anywhere."

        h2(class = "sec-title next"): text "Privacy"
        p(class = "lead"):
          text "What this site can see, which is all of it."
        dl(class = "dl group"):
          dt: text "Account"
          dd:
            span(class = "badge ok"): text "Not required"
            span(class = "muted"):
              text " Every published trace opens anonymously, whatever the "
              text "chain's coverage mode."
          dt: text "Ads"
          dd:
            span(class = "badge ok"): text "None"
          dt: text "Third-party requests"
          dd:
            span(class = "badge ok"): text "None"
            span(class = "muted"):
              text " No page fetches anything from a chain endpoint or any "
              text "other third party."
          dt: text "Telemetry"
          dd:
            span(class = "badge muted"): text "None"
            span(class = "muted"):
              # "Opt-in, off by default, and not yet implemented" described a
              # plan. The reader's question is whether anything reports back.
              text " Nothing on this site reports anything back."
          dt: text "What is logged"
          dd(class = "measure"):
            text "This site's own CDN logs, and nothing else. A page "
            text "load is a series of GETs against static files."
          dt: text "Record caps"
          dd:
            span(class = "badge ok"): text "None"
            span(class = "muted"):
              text " Address history is complete; it is paged by block range, "
              text "not truncated."
        p(class = "muted stack"):
          a(href = aboutUrl()): text "The full privacy summary →"

        # THESE TWO SECTIONS KEEP ONLY WHAT A READER CAN ACT ON.
        #
        # Both used to be a promised control followed by the reason it is not
        # here — "are both script operations, and this deployment ships none",
        # "are stored per browser, which needs script". A visitor on a settings
        # page wants to know what they can change; "the feature needs a
        # technology this build does not ship" is a note to whoever will build
        # it. What survives is the part that is TRUE AND USEFUL NOW and that
        # was buried at the end of each: nothing is stored beyond the ordinary
        # browser cache, and the theme and motion settings already follow the
        # system preference — which is a real answer to "how do I change the
        # theme?", and it was the last clause of a paragraph about script.
        h2(class = "sec-title next"): text "Storage"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "BlockTracer stores nothing beyond your browser's ordinary "
            text "cache, which your browser can clear."

        h2(class = "sec-title next"): text "Debugger"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "The theme and reduced motion follow your system settings — "
            text "change them there and this site follows."

        # THE "Advanced" SECTION IS GONE, HEADING AND ALL. Its entire content
        # was: "Registry override URL, for pointing a public build at a private
        # deployment. A build already reads its registry from the tree it was
        # built against; overriding that at run time is the part that needs
        # script. A self-hoster changes it at build time today, which is the
        # same capability without the switch."
        #
        # A heading with no setting under it, describing a control for people
        # who self-host, published to everyone who follows "Privacy & settings"
        # out of the footer. Its audience is someone deploying this software,
        # who reads DEPLOY.md and not a settings page; its subject is a build
        # flag they already have. Unlike Storage and Debugger there was no
        # residue worth keeping — no clause of it tells a visitor anything
        # about the site they are on.
