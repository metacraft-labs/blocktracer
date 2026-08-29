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
          text "Everything here is browser state. Nothing on this page is "
          text "sent anywhere, and there is nothing about data sources to "
          text "configure — a visitor chooses nothing that affects where a "
          text "byte comes from."

        h2(class = "sec-title next"): text "Privacy"
        p(class = "lead"):
          text "What this deployment can observe, which is the whole of it."
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
            span(class = "badge muted"): text "Off"
            span(class = "muted"):
              text " Opt-in, off by default, and not yet implemented — so "
              text "there is nothing switched on to switch off."
          dt: text "What is logged"
          dd(class = "measure"):
            text "This deployment's own CDN logs, and nothing else. A page "
            text "load is a series of GETs against static files."
          dt: text "Record caps"
          dd:
            span(class = "badge ok"): text "None"
            span(class = "muted"):
              text " Address history is complete; it is paged by block range, "
              text "not truncated."
        p(class = "muted stack"):
          a(href = aboutUrl()): text "The full privacy summary →"

        h2(class = "sec-title next"): text "Storage"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Local trace-cache usage, its ceiling and a clear button. "
            text "Measuring what a browser has cached, and clearing it, are "
            text "both script operations, and this deployment ships none — so "
            text "there is no number to show and no button that could act on "
            text "it. Until then nothing is stored beyond the HTTP cache, "
            text "which your browser already owns and can already clear."

        h2(class = "sec-title next"): text "Debugger"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Theme, keybinding set, pane layout and reduced motion. "
            text "The theme already follows your system preference through "
            text "prefers-color-scheme, and reduced motion is already "
            text "honoured — both are stylesheet-level and work now. The "
            text "toggle that would override the system preference, the "
            text "keybinding set and the persisted pane layout are stored per "
            text "browser, which needs script."

        h2(class = "sec-title next"): text "Advanced"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Registry override URL, for pointing a public build at a "
            b: text "private deployment. "
            text "A build already reads its registry from the tree it was "
            text "built against; overriding that at run time is the part that "
            text "needs script. A self-hoster changes it at build time today, "
            text "which is the same capability without the switch."
