// lib/era-analysis.mjs — does replay yield step at the declared boundaries, or decline with depth?
//
// Chain-Expansion CXP-3's yield method asks each chain to declare in advance which variable
// it expects to dominate its yield, and Recorder-Flow CXP-FLOW-5 declared `era`: yield
// steps at language/VM boundaries and is flat between them. The alternative this has to be
// able to report is a SMOOTH DECLINE WITH DEPTH, which is what a retention limit looks like —
// state thinning out as heights get older, whatever version ran there — and which refutes
// the era expectation. Until this module the verdict was a sentence written by hand, so
// nothing could have come out against the prediction.
//
// The two explanations are compared as weighted least-squares fits of per-point yield
// (`reproduced / attempted`, weighted by `attempted`):
//
//   * STEP: one mean per segment between consecutive declared boundaries.
//   * TREND: one straight line in height.
//
// Each is scored by its residual as a fraction of the flat model's (one mean for all), and
// the step model is charged for its extra parameters: AICc over the weighted residual. The
// verdict is `step` when the step fit wins and explains most of the variance, and
// `smooth-decline` when the trend fit wins, explains most of it, and rises with height
// (falls with depth). Anything else — too few points, no variance, neither fit convincing,
// or a trend that rises with depth — is `not-established`, with the reason.
//
// The boundaries are an INPUT, and must be declared independently of the yields judged:
// boundaries chosen by looking at where yield changes would make `step` true by
// construction. The caller states where its boundaries came from in `boundariesFrom`, and
// the verdict carries it.

const MIN_POINTS = 4;
const EXPLAINS = 0.5;   // a model must remove at least half the flat model's residual

function weightedMean(points) {
  const w = points.reduce((a, p) => a + p.attempted, 0);
  return w === 0 ? 0 : points.reduce((a, p) => a + p.attempted * p.y, 0) / w;
}

function sse(points, predict) {
  return points.reduce((a, p) => a + p.attempted * (p.y - predict(p)) ** 2, 0);
}

function aicc(n, k, rss) {
  const r = Math.max(rss, 1e-12 * n);
  const base = n * Math.log(r / n) + 2 * k;
  return n - k - 1 > 0 ? base + (2 * k * (k + 1)) / (n - k - 1) : Infinity;
}

/**
 * @param {{height: number, attempted: number, reproduced: number}[]} input
 * @param {number[]} boundaries heights at which a new segment begins
 * @param {string} boundariesFrom where the boundaries were declared
 */
export function judgeEra(input, boundaries, boundariesFrom) {
  const points = input.filter((p) => p.attempted > 0)
    .map((p) => ({ ...p, y: p.reproduced / p.attempted }));
  const result = { points: points.length, boundaries: [...boundaries].sort((a, b) => a - b),
                   boundariesFrom };
  if (points.length < MIN_POINTS) {
    return { ...result, verdict: 'not-established',
             reason: `${points.length} point(s) with an attempt, and the comparison needs ${MIN_POINTS}` };
  }
  const flatMean = weightedMean(points);
  const rssFlat = sse(points, () => flatMean);
  if (rssFlat === 0) {
    return { ...result, verdict: 'not-established',
             reason: `yield is ${flatMean.toFixed(3)} at every point, so nothing varies to explain` };
  }

  const segOf = (h) => result.boundaries.filter((b) => h >= b).length;
  const segMeans = new Map();
  for (const s of new Set(points.map((p) => segOf(p.height)))) {
    segMeans.set(s, weightedMean(points.filter((p) => segOf(p.height) === s)));
  }
  const rssStep = sse(points, (p) => segMeans.get(segOf(p.height)));

  // Weighted least squares on a centred height, so the slope is per block of height.
  const w = points.reduce((a, p) => a + p.attempted, 0);
  const hBar = points.reduce((a, p) => a + p.attempted * p.height, 0) / w;
  const sxx = points.reduce((a, p) => a + p.attempted * (p.height - hBar) ** 2, 0);
  const sxy = points.reduce((a, p) => a + p.attempted * (p.height - hBar) * (p.y - flatMean), 0);
  const slope = sxx === 0 ? 0 : sxy / sxx;
  const rssTrend = sse(points, (p) => flatMean + slope * (p.height - hBar));

  const n = points.length;
  const fit = {
    flatMean,
    step: { segments: segMeans.size, explained: 1 - rssStep / rssFlat,
            aicc: aicc(n, segMeans.size, rssStep),
            segmentMeans: [...segMeans].sort((a, b) => a[0] - b[0]).map(([, m]) => m) },
    trend: { slopePerMillionBlocks: slope * 1e6, explained: 1 - rssTrend / rssFlat,
             aicc: aicc(n, 2, rssTrend) },
  };
  const stepWins = fit.step.aicc < fit.trend.aicc;
  if (stepWins && fit.step.explained >= EXPLAINS && segMeans.size > 1) {
    return { ...result, fit, verdict: 'step',
             reason: `a step at the declared boundaries explains ${(100 * fit.step.explained).toFixed(0)}% `
               + `of the variance against ${(100 * fit.trend.explained).toFixed(0)}% for a trend with height` };
  }
  if (!stepWins && fit.trend.explained >= EXPLAINS && slope > 0) {
    return { ...result, fit, verdict: 'smooth-decline',
             reason: `yield declines smoothly with depth (a trend explains `
               + `${(100 * fit.trend.explained).toFixed(0)}%, a step at the declared boundaries `
               + `${(100 * fit.step.explained).toFixed(0)}%): the era expectation is REFUTED, and the `
               + 'suspected cause is retention — state thinning with depth, not a version edge' };
  }
  return { ...result, fit, verdict: 'not-established',
           reason: `neither fit is convincing: step ${(100 * fit.step.explained).toFixed(0)}%, `
             + `trend ${(100 * fit.trend.explained).toFixed(0)}% with slope `
             + `${(slope * 1e6).toFixed(3)} per million blocks` };
}

/**
 * The era probe's reading (`measurements/flow-era-edges.json`) as points: every replayed
 * pair member, one attempt each. An unreplayable one counts as attempted and not
 * reproduced, which is what it is.
 */
export function pointsFromEraProbe(reading) {
  return reading.edges.flatMap((e) => [e.below, e.above])
    .map((s) => ({ height: s.height, attempted: 1, reproduced: s.reproduced ? 1 : 0 }));
}
