# The pinned capture container (VD.0).
#
# Tier 1 of visual-design-iteration.md asks for an exact-hash check, and an
# exact-hash check that runs across heterogeneous runners, GPUs or OS versions
# measures the runner rather than the product. This image fixes the three
# things that decide the pixels:
#
#   1. THE BROWSER BUILD — from a base image pinned by DIGEST, not by tag. A
#      tag is a moving target: `v1.62.1-noble` will be rebuilt with a newer
#      base OS and a newer Chromium patch, and every stored hash would change
#      with nothing in the product having moved.
#   2. THE FONTS — the base image's font set is fixed by the same digest, and
#      fonts-local.conf removes the remaining sources of glyph variance
#      (hinting, autohinting, subpixel order, LCD filter, embedded bitmaps).
#   3. THE RENDERER FLAGS — defined once in lib/determinism.mjs and applied
#      identically on the host and in the container, so the two paths cannot
#      drift apart.
#
# ARCHITECTURE IS PART OF THE PIN. amd64 and arm64 Chromium do not rasterise
# text identically, so a hash produced on one is not comparable with a hash
# produced on the other. run-in-container.sh records the resolved image id and
# the architecture in the manifest, so a cross-architecture comparison is
# visible as one rather than reported as a regression.
#
# Base: mcr.microsoft.com/playwright:v1.62.1-noble
#   index  sha256:dcc5531e97840b9b5e794f2814476b21571c5124a3fca2267d73041f56e7580e
#   amd64  sha256:c091b21d9fae78c76e85cd4356431e9b018402f172a214fc7d7a5e9a7e29d8ac
#   arm64  sha256:941cc91e5022880ac1d14ae90b476b624deb6399dbbc28d612d5d5bd7928fcbd
#
# Only plain COPY/RUN/ENV are used: no BuildKit heredocs and no `# syntax=`
# directive, so this builds under the classic builder and under any BuildKit
# version without first fetching a frontend image.

FROM mcr.microsoft.com/playwright@sha256:dcc5531e97840b9b5e794f2814476b21571c5124a3fca2267d73041f56e7580e

COPY fonts-local.conf /etc/fonts/local.conf

# Build the fontconfig cache into the image so it is not rebuilt — in a
# filesystem-order-dependent way — on first run inside a fresh container.
RUN fc-cache -f >/dev/null 2>&1 || true

# The pinned Playwright npm package, installed at the filesystem root so Node's
# ESM resolution finds it by walking up from /work/tools/capture/capture.mjs
# even when the bind-mounted repo carries no node_modules of its own. A repo
# that DOES carry one wins, which is why run-in-container.sh asserts the two
# versions agree before it captures anything: a skew between the npm package
# and the browser build in this image is exactly the drift tier 1 exists to
# make impossible.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
RUN npm install --prefix / --no-audit --no-fund --loglevel=error playwright@1.62.1 \
 && echo '1.62.1' > /vd0-playwright-version \
 && chmod -R a+rX /node_modules /vd0-playwright-version

# Fixed locale and timezone: both reach number formatting, date formatting and
# occasionally font fallback. HOME must be writable by whatever uid the run
# script maps in.
ENV VD0_IN_CONTAINER=1 \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_OPTIONS=--no-warnings \
    HOME=/tmp

WORKDIR /work

# The repo is bind-mounted at /work; the site is built on the host beforehand
# (this image deliberately carries no Nim toolchain), so the default command
# never rebuilds.
ENTRYPOINT ["node"]
CMD ["tools/capture/capture.mjs", "--no-build"]
