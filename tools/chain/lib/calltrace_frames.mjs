// The call trace, built from a container's event stream — the part of
// `derive-calltrace.mjs` that is arithmetic rather than I/O.
//
// It is a module so it can be DRIVEN WITHOUT A CONTAINER. `calltrace-fold-selftest.mjs`
// feeds it hand-built event streams to prove the refusals fire and that the fold
// policy can be made to go red, which needs neither `ct-print` nor a `.ct` on
// disk. The tool keeps the file reading, the snapshot walk and the reporting;
// everything a reviewer would want to check by hand lives here.
//
// It returns the frames in STREAM ORDER — the order the recording opened them,
// which is also depth-first order — because that is the order the pane renders
// and the order `session_view.selfCost` walks. Nothing is dropped, reordered or
// summarised: a fold is a MARK on a frame, never its removal.

/** A `Return` arrived with nothing open, or a `Call` named a function the container never declared. */
export class MalformedCallStream extends Error {}

/**
 * Build the frame list for one container's decoded event stream.
 *
 * `events` is `ct-print --events` output: the flat, `type`-tagged array. Only
 * `Path`, `Function`, `VariableName`, `Call`, `Return` and `Step` are read.
 *
 * `rules` is the fold policy — pass `[]` for none. `foldRuleFor` is injected so
 * the self-test can supply a rule that matches nothing (or everything) without
 * editing the policy file.
 */
export function buildFrames(events, { rules, foldRuleFor }) {
  // The interning tables, in the order the container declares them.
  //
  // A `Function` event is a DEFINITION and a `Call` event is an INVOCATION that
  // references one by index; the two are separate streams and this must not
  // assume they interleave one-to-one. On the AVM-context shape they happen to;
  // on the Noir shape they emphatically do not — 35 definitions carry 46 calls,
  // because a function entered twice is declared once.
  const functions = events.filter((e) => e.type === 'Function');
  const varNames = events.filter((e) => e.type === 'VariableName').map((e) => e.name);

  // `Path` events arrive in interning order, so the INDEX is the `path_id` a
  // `Function` quotes. Index 0 is the recorder's pseudo-path — a synthetic
  // `/aztec/<tx>.avm` it files unplaceable coordinates under — and a frame there
  // has no source position at all.
  const paths = events.filter((e) => e.type === 'Path').map((e) => e.name);

  let step = 0;
  const open = [];
  const frames = [];
  let calls = 0;
  let returns = 0;

  for (const e of events) {
    if (e.type === 'Step') {
      // CHARGED TO THE INNERMOST OPEN FRAME, WHICH IS THE FRAME IT RAN IN. This
      // is what lets a folded node say "22 steps" rather than "2 frames" — the
      // number that actually tells a reader how much of the trace is behind the
      // triangle. A step with nothing open is charged to nothing, which happens
      // only if a container puts steps outside its own toplevel.
      const inner = open[open.length - 1];
      if (inner !== undefined) inner.ownSteps += 1;
      step++;
      continue;
    }

    if (e.type === 'Call') {
      calls++;
      const fn = functions[e.function_id];
      if (!fn) {
        throw new MalformedCallStream(
          `a Call references function_id ${e.function_id} and the container declares `
          + `${functions.length} function(s). Refusing to build a frame with no definition `
          + 'behind it.');
      }
      // THE PATH, RESOLVED — not dropped, and not renumbered.
      //
      // `path_id === 0` is the pseudo-path and means "no source position", so it
      // becomes `null` rather than the synthetic filename; the declared `line: 1`
      // beside it is a slot filler and goes with it. Anything else is a real
      // interned Noir file and is carried through as written.
      //
      // A `path_id` past the end of the table is a container this tool cannot
      // read, not a frame to place at index 0: silently folding it onto the
      // pseudo-path would report "no source" for a frame that HAS one.
      const pathId = fn.path_id ?? 0;
      if (pathId >= paths.length) {
        throw new MalformedCallStream(
          `frame '${fn.name}' quotes interned path ${pathId} and the container declares `
          + `${paths.length} path(s). Refusing to place a frame on a path the container `
          + 'does not have.');
      }
      const path = pathId === 0 ? null : paths[pathId];
      const frame = {
        name: fn.name,
        depth: open.length,
        // The step the frame opened at. On the AVM-context shape both frames
        // open at 0, before the first Step event is read.
        step,
        path,
        line: path === null ? null : (fn.line ?? null),
        args: (e.args ?? []).map((a) => ({
          name: varNames[a.variable_id] ?? null,
          value: a.value?.text ?? (a.value?.i !== undefined ? String(a.value.i) : null),
        })),
        endStep: null,
        // Internal, and stripped before the frame is written out — see `strip`.
        ownSteps: 0,
        children: [],
      };
      const parent = open[open.length - 1];
      if (parent !== undefined) parent.children.push(frame);
      open.push(frame);
      frames.push(frame);
      continue;
    }

    if (e.type === 'Return') {
      returns++;
      const frame = open.pop();
      // A Return with nothing open is a malformed stream, not a frame at
      // depth -1. Refusing beats writing a call trace that claims a structure
      // the container does not have.
      if (!frame) {
        throw new MalformedCallStream(
          'a Return event closes a frame that was never opened. Refusing to build a '
          + 'malformed call trace.');
      }
      frame.endStep = step;
    }
  }

  foldSubtrees(frames, { rules, foldRuleFor });

  return { frames: frames.map(strip), calls, returns, steps: step, paths };
}

/**
 * Mark the subtrees the pane starts with closed, and count what is behind each.
 *
 * THE FOLD LANDS ON THE OUTERMOST MATCHING FRAME. Once a subtree is closed there
 * is no reason to walk inside it looking for more reasons to close it — the
 * reader sees one shut node, not a shut node full of shut nodes they cannot see.
 *
 * A FRAME WITH NO CHILDREN IS NEVER MARKED FOLDED, however well it matches.
 * Folding is a claim that there is something inside; a leaf drawn as folded puts
 * a disclosure triangle on an empty subtree, and a reader opens it and nothing
 * happens. `std/cmp.nr`'s `derive_eq` is the case that makes this concrete: it
 * matches `noir-stdlib` and it is a leaf on this recording.
 */
function foldSubtrees(frames, { rules, foldRuleFor }) {
  const countFrames = (n) => n.children.reduce((acc, c) => acc + 1 + countFrames(c), 0);
  const countSteps = (n) => n.ownSteps + n.children.reduce((acc, c) => acc + countSteps(c), 0);

  const walk = (node) => {
    const rule = node.children.length > 0 && node.path !== null
      ? foldRuleFor(node.path, rules)
      : null;
    if (rule !== null) {
      node.foldedBy = rule.id;
      node.foldWhy = rule.why;
      node.hiddenDescendants = countFrames(node);
      node.hiddenSteps = countSteps(node);

      // A CROSS-CHECK WAS WRITTEN HERE AND WITHDRAWN, AND THE REASON IS WORTH
      // MORE THAN THE CHECK WAS.
      //
      // It compared `hiddenSteps` — the sum of steps charged frame by frame over
      // the subtree — against `endStep - step`, the recording's own step clock
      // across the frame's life, and refused a disagreement. It read as the
      // repository's standing "two producers of one number" contract applied to
      // the one figure a reader is asked to trust about something they cannot
      // see.
      //
      // IT COULD NOT BE MADE TO KILL. `calltrace-fold-selftest.mjs` aimed an arm
      // at it — a fold point's `endStep` moved by three — and the arm SURVIVED,
      // because the two quantities are not two producers at all: both are read
      // off the same single walk. Every Step between a frame's `Call` and its
      // `Return` is charged to that frame or to a descendant, by construction,
      // so the sum IS the span. On a well-formed stream they cannot differ, and
      // on a malformed one the nesting refusals below fire first.
      //
      // So it is gone rather than kept as a green line nothing could redden. The
      // gates that DO bite on these numbers are the never-fold-a-leaf rule just
      // below, `derive-calltrace.mjs`'s declared-versus-marked totals, and
      // `ingest.nim`'s refusal to publish a summary the rows contradict — all
      // three of which have arms that kill.
      return; // outermost wins: do not descend
    }
    for (const c of node.children) walk(c);
  };

  for (const f of frames) {
    if (f.depth === 0) walk(f);
  }
}

/**
 * The wire shape. `children` and `ownSteps` are working state and do not ship:
 * the frames go out FLAT with a `depth` on each, which is what the pane renders
 * and what `session_view.selfCost` already walks. A folded frame carries its two
 * counts and the id and sentence of the rule that closed it, so the pane can
 * tell the reader WHY a node came up shut instead of leaving them to guess.
 */
function strip(f) {
  return {
    name: f.name,
    depth: f.depth,
    step: f.step,
    path: f.path,
    line: f.line,
    args: f.args,
    endStep: f.endStep,
    foldedBy: f.foldedBy ?? null,
    foldWhy: f.foldWhy ?? null,
    hiddenDescendants: f.hiddenDescendants ?? 0,
    hiddenSteps: f.hiddenSteps ?? 0,
  };
}
