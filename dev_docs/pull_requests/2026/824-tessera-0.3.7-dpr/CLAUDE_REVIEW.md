# PR #824 — Tessera 0.3.7 pin and device-pixel warm gate

**Author:** alexdont (`tessera-0.3.7-dpr`) · **Merged:** 2026-09-17 · **Reviewed:** 2026-09-17 (post-merge)

3 files: the Tessera CDN pin moves from `v0.3.6` to `v0.3.7`, the viewer's neighbour
warm gate (`ViewerKeydown._warm`) multiplies the column width by
`devicePixelRatio`, a JS test covers the change, and `mix.lock` changes.

## Verdict

The change is correct, but its test never ran. The gate now counts the same
pixels Tessera 0.3.7 counts. `displayedFullWidth/1` in
`deps/tessera/priv/static/tessera.js` returns `scale × canvas-width ×
devicePixelRatio` and compares it against `rung width × UPGRADE_HEADROOM
(1.1)`. The hook compares `column width × dpr` against `1920 × 1.1`. At fit the
image fills at most the column, so the column width is the right upper bound.
The CDN tag `v0.3.7` matches the Hex release that `mix.lock` resolves to.

## Findings

### BUG - MEDIUM — the PR's JS test, and one other, never ran in the gate (FIXED)

`mix test.js` (part of `mix precommit`) runs `Path.wildcard("test/js/*.test.cjs")`.
The PR adds its test to `test/js/neighbor_prefetch_test.cjs`, a file with an
underscore in its name, so the gate has never run any of that file's 7 tests.
`test/js/transport_cache_test.cjs` has the same problem. Run by hand, one of its
tests failed. `"phoenix.js really does use that key shape"` climbed four
directories from `test/js` instead of two, so it read `/deps/phoenix/...` and hit
`ENOENT`. The failure stayed hidden because the gate never ran the file.

Fix: renamed both files to `*.test.cjs`, fixed the `deps/phoenix` path, and
updated the `node --test` line in each header. `mix test.js` now runs 146 tests,
and all pass.

### IMPROVEMENT - MEDIUM — the stale PR branch downgraded swoosh in `mix.lock` (FIXED)

The branch's lock file was older than main's, so the merge moved `swoosh`
from 1.28.1 back to 1.28.0. Nothing in the PR needed that. Restored 1.28.1 with
`mix deps.update swoosh`.

### NITPICK — the comment above the gate still said "CSS px" (FIXED)

The block comment described the threshold as "1920 x 1.1 CSS px". The new line
right below it converts to device px, so the two contradicted each other. The
comment now says device px.

### NITPICK — `mix.exs` keeps `{:tessera, "~> 0.3.0"}` (not changed)

The dpr fix lives entirely in the JS that the CDN serves at the pinned tag. No
Elixir API from 0.3.7 is used, so there is nothing to raise the floor for.
