## Settings (`/settings`) — Page-Descriptions §12.
##
## "Entirely client-side; nothing leaves the browser."
##
## ## Why there is not one control on this page
##
## §12's groups are all *browser* state — a local cache ceiling, a theme, a
## keybinding set, a registry override. Reading or writing any of them needs
## script, and this client ships none. §13 already settled what to do about
## that, for the copy button: "a copy *button* there would be a control that
## cannot succeed — which this product does not ship."
##
## A settings page of controls that silently do nothing is the same defect with
## more surface area, and it is worse here than elsewhere, because a settings
## control that appears to accept a value has told the user their preference was
## recorded.
##
## ## WHAT THE PAGE SAYS INSTEAD, AND WHY IT IS NO LONGER FOUR GROUPS
##
## It used to answer that by giving each of §12's four groups a paragraph
## stating what it WILL control and why it cannot act yet — "are both script
## operations, and this deployment ships none", "are stored per browser, which
## needs script". Read as settings copy, that is four promises of features and
## no settings, and the test a settings page has to pass is whether a user can
## tell what a control does BEFORE touching it. There were no controls to tell
## them about.
##
## So a group survives only where something is TRUE FOR THE READER NOW:
##
##   * **Privacy** — untouched in substance. It is the only page in the product
##     that answers "what can this site observe about me", and the answer is
##     complete today and needs no script.
##   * **Your browser** — Storage and Debugger merged. Between them they held
##     exactly two facts a reader can act on, and both were the last clause of a
##     paragraph about script: nothing is stored beyond the ordinary cache, and
##     the theme and motion follow the system settings. Two facts is one group.
##   * **Advanced** was deleted outright. Its subject was a registry override
##     URL for people self-hosting this software, who read DEPLOY.md and not a
##     settings page. When a setting cannot be explained simply it is usually
##     because it is internal, and that one was.

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
          text "There is nothing to set here. BlockTracer has no account and "
          text "keeps nothing about you, so this page simply states what it "
          text "does and does not do."

        h2(class = "sec-title next"): text "Privacy"
        p(class = "lead"):
          text "What this site can see, which is all of it."
        dl(class = "dl group"):
          dt: text "Account"
          dd:
            span(class = "badge ok"): text "Not required"
            span(class = "muted"):
              text " Every published trace opens anonymously."
          dt: text "Ads"
          dd:
            span(class = "badge ok"): text "None"
          dt: text "Third-party requests"
          dd:
            span(class = "badge ok"): text "None"
            span(class = "muted"):
              text " No page fetches anything from anyone else."
          dt: text "Telemetry"
          dd:
            span(class = "badge muted"): text "None"
            span(class = "muted"):
              text " Nothing on this site reports anything back."
          dt: text "What is logged"
          dd(class = "measure"):
            text "This site's own CDN logs, and nothing else."
          dt: text "Record caps"
          dd:
            span(class = "badge ok"): text "None"
            span(class = "muted"):
              text " Address history is complete, not truncated."

        h2(class = "sec-title next"): text "Your browser"
        dl(class = "dl group"):
          dt: text "Stored on your device"
          dd(class = "measure"):
            text "Nothing beyond your browser's ordinary cache, which your "
            text "browser can clear."
          dt: text "Theme and motion"
          dd(class = "measure"):
            text "Both follow your system settings. Change them there and "
            text "this site follows."
        p(class = "muted stack"):
          a(href = aboutUrl()): text "More about BlockTracer →"
