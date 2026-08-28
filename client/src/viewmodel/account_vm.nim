## viewmodel/account_vm.nim
##
## `AccountVM` — Front-End-Architecture §3, last row: "Signed-in state,
## remaining generation quota, tier, reset time. Reached **only** from the
## generation-request path — no page may gate rendering on it".
##
## ## The honest status of this VM: the rule is built, the inputs do not exist
##
## There is no sign-in service, no quota service and no account endpoint in
## this repository, and there is a stronger statement than "not yet": **the
## read path is anonymous by construction and must stay that way.**
## CodeTracer-Identity.md §4 makes it normative, M12a's deliverable list carries
## "No identity anywhere in this package", and
## `ci/test/client-sdk-boundary.sh` scans the Client SDK's whole graph for the
## vocabulary — `cookie`, `authorization`, `bearer`, `accessToken`, `userId` —
## and fails the build on a hit in code.
##
## So this VM cannot fetch anything, ever, and it does not try. What it holds
## is state the *shell* supplies from whatever sign-in surface eventually
## exists, and what it enforces is §3's rule, which is the part that has to be
## true from the first day:
##
## > Reached **only** from the generation-request path — **no page may gate
## > rendering on it.**
##
## That rule is a claim about the rest of the codebase, so this module makes it
## checkable rather than merely stating it: `mayRequestGeneration` is the only
## memo any other module has a reason to read, and **no ViewModel in this
## package imports `account_vm`** — only `viewmodel.nim`, the barrel, does, and
## a barrel re-exporting a module is not a dependency on it. (One command
## checks the claim: `grep -rn account_vm client/src/ | grep -v account_vm.nim`
## should name the barrel and nothing else.)
##
## `client/tests/test_chain_viewmodels.nim` asserts the second half mechanically
## — every other ViewModel is constructed, driven through every degraded state,
## and resolved, with **no `AccountVM` in existence**, because the test's
## `Layer` record has no field for one and no `create*VM` takes one. A page that
## started gating on an account would make that suite fail to compile.
##
## Anonymous readers are the default and the majority: every published trace is
## fully usable with no account at all (Static-Site-Architecture.md §6's last
## row is explicit that "all published content, including every existing trace,
## stays fully usable and anonymous" even when the generation service is down).
## `signedOut()` is therefore the constructor's initial state and not an error
## state.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

type
  QuotaTier* = enum
    qtAnonymous = "anonymous"
      ## Not signed in. Reads everything; requests nothing.
    qtFree = "free"
    qtPaid = "paid"

  AccountVM* = ref object of ViewModel
    # -- State, all supplied by the shell --
    signedIn*: Signal[bool]
    tier*: Signal[QuotaTier]
    quotaRemaining*: Signal[int]
    quotaLimit*: Signal[int]
    resetSeconds*: Signal[int]
      ## Seconds until the quota window resets, as the shell last learned it.
      ## A duration rather than a timestamp, so this VM holds no clock — the
      ## same reason `GenerationJobVM.elapsedSeconds` is ticked from outside.

    # -- Derived --
    mayRequestGeneration*: Memo[bool]
      ## The ONE memo the rest of the product has a reason to read, and only
      ## from the generation-request path. §14.1's `refused` row lists "out of
      ## quota" as a reason a request is refused, so this is what stops the
      ## affordance being offered rather than what stops a page rendering.
    exhausted*: Memo[bool]
    hasQuotaInformation*: Memo[bool]
      ## Whether the shell has told this VM anything. `false` is not "no
      ## quota": a signed-in user whose quota has not been fetched must not be
      ## shown "0 remaining", which is the difference between an unknown and a
      ## zero that §14 keeps insisting on elsewhere.

proc setQuota*(vm: AccountVM; remaining, limit, resetSeconds: int) =
  vm.quotaRemaining.val = remaining
  vm.quotaLimit.val = limit
  vm.resetSeconds.val = resetSeconds

proc signIn*(vm: AccountVM; tier: QuotaTier) =
  vm.signedIn.val = true
  vm.tier.val = tier

proc signOut*(vm: AccountVM) =
  vm.signedIn.val = false
  vm.tier.val = qtAnonymous
  vm.quotaRemaining.val = 0
  vm.quotaLimit.val = 0
  vm.resetSeconds.val = 0

proc createAccountVM*(): AccountVM =
  withViewModel proc(dispose: proc()): AccountVM =
    let vm = AccountVM(
      signedIn: createSignal(false),
      tier: createSignal(qtAnonymous),
      quotaRemaining: createSignal(0),
      quotaLimit: createSignal(0),
      resetSeconds: createSignal(0),
    )

    vm.hasQuotaInformation = createMemo(proc(): bool = vm.quotaLimit.val > 0)

    vm.exhausted = createMemo(proc(): bool =
      vm.hasQuotaInformation.val and vm.quotaRemaining.val <= 0)

    vm.mayRequestGeneration = createMemo(proc(): bool =
      # Signed out is a definite no — §14.1a's Renew and Generate are both
      # "behind sign-in" — and an unknown quota is a definite no as well,
      # because offering a request that the service will refuse is §14's retry
      # that cannot succeed wearing a different hat.
      vm.signedIn.val and vm.hasQuotaInformation.val and
        vm.quotaRemaining.val > 0)

    vm
