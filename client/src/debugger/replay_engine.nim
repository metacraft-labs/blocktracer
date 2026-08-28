## Where the browser replay engine is fetched from.
##
## The engine — `worker.js`, `gateway-client.js` and `pkg/db_backend_bg.wasm` —
## is **already built and published** by CodeTracer's own
## `deploy-web-codetracer.yml`, and BlockTracer is its intended cross-origin
## consumer. Nothing here builds a worker or packages wasm; this module decides
## one thing, which is the URL prefix the future hydration entry point loads
## them from.
##
## ## Why it is a build-time value and not a constant in a page
##
## CodeTracer-Embed-SDK.md §5.1 calls this `assetBase` and warns that it **must
## not default to a cross-origin URL**. That warning is the whole design here:
##
##   * The **default is same-origin** (`/replay-engine/`). A build that says
##     nothing loads nothing from anybody else, hydration does not happen, and
##     §7.0's guarantee holds unchanged — "no state renders less than the
##     pre-hydration page". A default that silently reached a third-party
##     origin would make every deployment of this repository a client of a host
##     its operator never named.
##
##   * The cross-origin case is **explicit**, one `-d:` away, and recorded in
##     the built page so a reader can see which origin a given build trusts.
##
## ## Which origin a cross-origin build should name
##
## `https://ide.codetracer.com` is the stable product domain for the in-browser
## Cloud IDE. It is a custom domain on the **same** `web-codetracer` Cloudflare
## Pages project as `https://web-codetracer.pages.dev`, so it serves the
## identical bundle with the right CORS headers (`access-control-allow-origin:
## *`, `Accept-Ranges` and `Content-Range` exposed, so range requests work) —
## it is the origin a cross-origin build should name. `https://web.codetracer.com`
## is deliberately NOT that host: it serves a **different, authenticated
## application** (`/worker.js` redirects to a login page and the wasm 404s),
## which is exactly why the IDE was given its own `ide.` name rather than a
## rename that would have broken that app's consumers.
##
## Even so, no domain is baked into the source: a compile-time default that
## reached any third-party origin would make every deployment of this repository
## a client of a host its operator never named. The deploy decides
## (`-d:replayEngineBase=https://ide.codetracer.com/`); this module only makes
## the decision expressible.

const ReplayEngineBase* {.strdefine: "replayEngineBase".} = "/replay-engine/"
  ## The URL prefix the engine's assets live under, with a trailing slash.
  ##
  ## Override at build time (the production IDE origin):
  ##   nim c -d:replayEngineBase=https://ide.codetracer.com/ …

func isCrossOrigin*(base: string): bool =
  ## Whether `base` names another origin.
  ##
  ## Derived from the value rather than carried as a second flag, because two
  ## fields that must agree are one field and a bug: a build could otherwise
  ## declare a cross-origin base and a `false`, and the page would report the
  ## opposite of what it loads.
  ##
  ## Protocol-relative (`//host/…`) counts: it is a different origin whenever
  ## the host differs, and a page cannot tell that it does not at build time.
  base.len > 0 and (base.len >= 2 and base[0 .. 1] == "//" or
                    base.len >= 7 and base[0 .. 6] == "http://" or
                    base.len >= 8 and base[0 .. 7] == "https://")

func replayEngineIsCrossOrigin*(): bool = isCrossOrigin(ReplayEngineBase)

const ReplayEngineWasmBytes* = 18_094_114
  ## The measured size of `pkg/db_backend_bg.wasm` as published.
  ##
  ## Recorded because it is a **design constraint, not a statistic**: 18 MB on
  ## the critical path is why Page-Descriptions §7.0 makes the transaction page
  ## the debugger's loading state rather than a waiting room, and why the debug
  ## route renders a complete, positioned first frame from published data
  ## before any of it is fetched. A page that blocked on this would be blank
  ## for seconds on a good connection.
  ##
  ## It is shown to the visitor, in the honest phase line, for the same reason:
  ## "loading" with no quantity is the indeterminate spinner §8 rules out,
  ## wearing words.

func approxMegabytes*(bytes: int): string =
  ## `18094114` → `"18 MB"`.
  ##
  ## Decimal megabytes, not mebibytes: the figure exists to set a visitor's
  ## expectation, and the number a browser's own download UI shows them is the
  ## decimal one. Reporting 17 for a file every other tool calls 18 would be
  ## technically defensible and read as an error.
  ##
  ## Whole units, because a decimal place would imply a precision the figure
  ## does not have between one deploy of the engine and the next.
  $((bytes + 500_000) div 1_000_000) & " MB"
