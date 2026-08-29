## Contract source (`/{chain}/address/{address}/code`) — Page-Descriptions §10.
##
## The verified-source browser: what BlockTracer holds for the code at an
## address, where it came from, and the source itself.
##
## ## The source is highlighted by the SAME lexer the debugger uses
##
## `debugger/source_highlight.nim` and `components/debugger.tokenClass` are
## imported rather than reimplemented. That is not code-sharing for its own
## sake: a reader who steps a transaction and then opens the contract's source
## is looking at the same bytes twice, and two lexers would eventually disagree
## about them — which of the two is right being unanswerable from the page. The
## palette is the same `--bt-syntax-*` roles in both registers, so what changes
## between the debugger and here is the density, not the meaning of a colour.
##
## ## What the page does when there is nothing to browse
##
## §14's "No verified source" row. Two shapes, and they are different states:
##
##   * **No code at this address at all** — an account, not a contract. There is
##     no verification question to answer.
##   * **Code, and no bundle for its hash** — the contract is real and
##     unverified. This is where §14's "instruction-level stepping, with the
##     supply-sources action prominent" belongs, and the page says both halves:
##     that stepping still works at instruction level (the fidelity ladder's
##     floor, which holds with no source at all), and how a bundle would arrive.
##
## Neither renders as an empty file tree.
##
## ## Two of §10's six sections have no published source, and say so
##
## The ABI/interface view and the storage layout live in the bundle's `debug`
## object, which the demo producer publishes empty — a Noir circuit has no
## Solidity-shaped storage layout to publish. They are stated as absent rather
## than drawn as empty panels, and "every function in the ABI view links to
## transactions that called it" is conditional on an ABI existing at all.

import std/strutils
import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../debugger/source_highlight
import ../debugger/session_view   # `pathSlug` — the same anchor scheme the session uses
import ../components/debugger
import ../components/degraded

proc renderFile(f: SourceFile, language: string): string =
  ## One source file, lexed and numbered.
  let lines = splitLines(f.content)
  let tokens = highlightLines(lines, profileForDocument(f.path, language))
  ui:
    tdiv(class = "codefile", id = "file-" & pathSlug(f.path)):
      tdiv(class = "codehead"):
        span(class = "mono"): text f.path
        span(class = "muted"): text $lines.len & " lines"
      tdiv(class = "codeview"):
        for i, line in lines:
          tdiv(class = "codeline"):
            span(class = "gutter"): text $(i + 1)
            span(class = "t"):
              if i < tokens.len and tokens[i].len > 0:
                for tok in tokens[i]:
                  # `tkPlain` gets no span — the same rule the debugger's
                  # source pane follows, so the two renderings have the same
                  # element count for the same bytes.
                  if tokenClass(tok.kind).len == 0:
                    text tok.text
                  else:
                    span(class = tokenClass(tok.kind)): text tok.text
              else:
                # An unknown language lexes to nothing at all, and the honest
                # rendering of that is the line as it was — never a guess at
                # which words are keywords.
                text line

proc codePage*(chain: string, address: string, code: seq[SourceBundleView],
               deployments: seq[string],
               degradation: ChainDegradation,
               note: DegradationNotice): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainUrl(chain)): text chain
          span(class = "sep"): text "/"
          a(href = addressUrl(chain, address)): text truncHash(address)
          span(class = "sep"): text "/"
          span: text "code"

        tdiv(class = "eyebrow"): text "Verified source"
        # `titlerow`, for the reason `pages/address.nim` states: `.identifier`
        # is inline-block, so a bare heading and the full value beneath it
        # would share a line.
        tdiv(class = "titlerow"):
          h1(class = "h1 identifier"): text truncHash(address)
        p(class = "identifier lead tight"): text address

        raw degraded.notice(degradation, note)

        if code.len == 0:
          tdiv(class = "stub group"):
            tdiv(class = "measure"):
              b: text "No code is bound to this address. "
              text "The published tree records a code binding as a code edge "
              text "on the transactions that ran it, and this address has "
              text "none — so it is an account, and there is no verification "
              text "question to answer for it."
          p(class = "muted stack"):
            a(href = addressUrl(chain, address)):
              text "← Back to this address"
        else:
          for b in code:
            tdiv(class = "group"):
              h2(class = "sec-title"): text "Verification"
              dl(class = "dl"):
                dt: text "Code hash"
                dd:
                  span(class = "identifier"): text b.codeHash
                dt: text "Status"
                dd:
                  if b.resolved:
                    span(class = "badge ok"): text b.match & " match"
                  else:
                    span(class = "badge muted"): text "Unverified"
                if b.resolved:
                  dt: text "Provider"
                  dd(class = "mono"): text b.provider
                  dt: text "Compiler"
                  dd(class = "mono"):
                    text b.compilerName & " " & b.compilerVersion
                  dt: text "Language"
                  dd(class = "mono"): text b.language
                  dt: text "Bundle"
                  dd:
                    span(class = "identifier"): text b.sourceBundleId
                else:
                  dt: text "Why"
                  dd(class = "measure"): text b.reason

            if not b.resolved:
              # §14: "No verified source → Instruction-level stepping, with the
              # supply-sources action prominent." Both halves, because the
              # first is what stops this reading as a dead end: the product
              # still works on this contract, at a lower fidelity that it names.
              tdiv(class = "stub"):
                tdiv(class = "measure"):
                  b: text "This contract is unverified, and it is still "
                  b: text "debuggable. "
                  text "Instruction-level stepping is the fidelity ladder's "
                  text "floor and holds with no source at all: the trace "
                  text "carries positions and values, and what is missing is "
                  text "the text to show them against. Publishing a build "
                  text "output whose bytes hash to the code hash above "
                  text "resolves it for every deployment of the same code, "
                  text "not only for this address."
            else:
              tdiv(class = "group"):
                h2(class = "sec-title"): text "Sources"
                tdiv(class = "filetree"):
                  for f in b.files:
                    a(class = "mono", href = "#file-" & pathSlug(f.path)):
                      text f.path
                for f in b.files:
                  raw renderFile(f, b.language)

              tdiv(class = "stub"):
                tdiv(class = "measure"):
                  b: text "This bundle publishes no ABI and no storage "
                  b: text "layout. "
                  text "§10's interface view and slot mapping are rendered "
                  text "from the bundle's debug object, and this producer "
                  text "writes an empty one — a circuit has no "
                  text "contract-shaped storage layout to declare. Where a "
                  text "bundle carries them, the interface view is also what "
                  text "links each function to the transactions that called "
                  text "it; with no ABI there is nothing to link from, so the "
                  text "link is absent rather than broken."

          tdiv(class = "group"):
            h2(class = "sec-title next"): text "Deployments"
            if deployments.len <= 1:
              tdiv(class = "stub"):
                tdiv(class = "measure"):
                  text "This code hash is bound to one address in this "
                  text "generation. Source is keyed by code hash rather than "
                  text "by address, so a second deployment of the same "
                  text "bytecode would appear here already verified — that is "
                  text "what keying by code hash buys."
            else:
              ul(class = "linklist"):
                for a2 in deployments:
                  li:
                    a(class = "addr", href = addressUrl(chain, a2)):
                      text a2
