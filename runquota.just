# The RunQuota bridge variable, shared by every Justfile in this repository
# (`import 'runquota.just'` here, `import '../runquota.just'` from `client/`).
#
# `{{rq}}` in front of a heavy command makes the command take a lease from the
# host's RunQuota budget first and run at the width it was granted: `nim c`
# gets `--parallelBuild:N`, `nix build` gets `--max-jobs 1 --cores N`. Several
# checkouts or agent sessions on one host then share one budget instead of each
# assuming it owns every core. Where RunQuota is not available the variable is
# empty and the recipe runs the command as before.
#
#   RQ unset   auto: `runquota run --` when a `runquota` that has the `run`
#              verb is on PATH, otherwise empty.
#   RQ=        an empty value turns the bridge off.
#   RQ="runquota run --width 4 --"
#              any other value is used as the prefix (a fixed width, say).
#
# THE PROBE LOOKS FOR THE `run` VERB, NOT JUST FOR THE BINARY. A `runquota`
# that predates `run` does not reject it: it prints its usage and exits 0, so a
# bridged `just test` would pass without running a single test. `run
# --adapter list` answers with the adapter table on a build that has the verb.
rq := env_var_or_default("RQ", if `command -v runquota >/dev/null 2>&1 && runquota run --adapter list 2>/dev/null | grep -q '^adapters' && echo yes || true` == "yes" { "runquota run --" } else { "" })
