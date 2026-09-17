# PR #820 — Etcher 0.14 toolset, faster media viewer and browser

**Author:** alexdont (`etcher-wip`) · **Merged:** 2026-09-16 · **Reviewed:** 2026-09-16 (post-merge)

## Verdict

Good work that should ship. The perceived-speed changes rest on real causes, and the
comments explain each one:

- the viewer opens on the `small` variant the grid already has cached
- an instant stand-in shows the cached bitmap while the server replies
- hovering a card, or opening a neighbour, warms the next variants
- the folder sidebar collapses client-side first
- the three user-pref reads per viewer open are now one

The arrow-kind CHECK widening (V192) comes with a test that reads the tool list
from the template, so the next new tool can't ship without widening the kind list.

The review found two problems, both fixed and covered by tests. The migration was
renumbered V191 → V192 at merge time but still wrote the old version numbers. The
new `?file=` URL param added a way to load a file that skipped the browser's scope
check. Released in 2.27.0.

## Findings

### BUG - HIGH — `?file=` fallback skipped scope, type lock and uuid validation (FIXED)

`sync_viewer_from_params/2` handles a `file` that is not in the loaded listing (for
example on another page or in a hand-edited link). It fetched that file with a bare
`Storage.get_file(uuid)` and opened the viewer on it. Every other path in
`MediaBrowser` that loads a file by uuid (`rotate_file`, `delete_file`, restore, move)
first checks `Storage.within_scope?(file.folder_uuid, scope)`. This one did not, so:

- **Scope bypass.** A browser limited by `scope_folder_id` (a branding picker, a
  per-user media area) opened any file in the install if you pasted its uuid into
  `?file=`. It showed the filename, the signed variant URLs, metadata and the
  annotation layer.
- **`only_file_type` bypass.** An audio-only picker opened an image the same way.
- **System-managed rows.** Tessera tile chunks, which every listing hides, could be
  opened too.
- **Crash loop.** `?file=not-a-uuid` raised `Ecto.Query.CastError` inside `update/2`
  on mount, so the page never rendered.

**Fix:** a new `fetch_viewable_file/2` checks, in order: a valid uuid
(`PhoenixKit.Utils.UUID.valid?/1`), then `system_managed: false`, then
`within_scope?`, then the `only_file_type` lock. If any check fails, the viewer
stays closed. Four integration tests in `media_browser_test.exs`
(`"?file= fallback fetch"`) cover the in-scope happy path, the out-of-scope file,
the wrong type and the malformed uuid. The last three failed against the PR's code.

### BUG - MEDIUM — V192 wrote V191's version comments (FIXED)

`v192.ex` was written as V191 and renumbered when upstream took V191, but only the
module name changed. `up/1` stamped `'191'`, `down/1` stamped `'190'`, and the
rollback error said "Cannot roll back V191". `handle_version_recording/4` restamps
only multi-step runs. So a host at 191 that ran the single V192 step would still
read as version 191, and every later `ensure_current` / `phoenix_kit.update` would
try to run V192 again. The re-run is idempotent (DROP IF EXISTS + ADD), but the
`status` output is wrong. A rollback would also leave the table at 190 while V191's
column still exists.

**Fix:** the comments now stamp 192/191 and the error message is corrected. The
`ExpectedSchema` `@chain_hash` was recomputed for the edited file. The new
`test/phoenix_kit/migrations/version_comment_test.exs` checks every `vNNN.ex`: each
file must stamp `NNN`, and may stamp only `NNN` or `NNN - 1`. It failed on the PR's
V192, and all other migrations already pass.

### NITPICK — migration moduledoc (FIXED)

The V192 heading in `Postgres`'s moduledoc had no body text. The merge also removed
the blank line before `### V190`, which turned that heading into part of V191's
paragraph. Both are fixed.

### IMPROVEMENT - MEDIUM — hover prefetch warms `large` for every card crossed (NOT FIXED)

`InstantViewer` warms both `small` and `large` on `pointerover`. Moving the pointer
across a grid of 50 cards starts 50 downloads of the 1920px variant, which is real
bandwidth on a metered or slow connection. The URLs are deduplicated per session,
so each file is fetched at most once. Not changed here, because the tradeoff is the
author's and was tuned in a browser. A cheap middle ground would warm `small` on
hover and `large` on `pointerdown` only.

### NITPICK — client-side toggle vs server-driven changes (NOT FIXED)

`FolderExplorer`'s `JS.toggle_class` swap is sticky across patches. That is correct
for the chevron-initiated round trip. If `sidebar_collapsed` ever changes for another
reason (none does today), the sticky class would fight the re-render. This is noted
for whoever adds a second writer.

## Verified premises

- **Nav fast path.** `nav_matches_current?/2` runs only after `init_socket` has
  assigned `search_query` / `current_page` / `filter_orphaned` / `file_view`. On
  first mount at root, the fast path correctly skips a second listing load.
- **Pref consolidation.** `viewer_user_prefs(nil)` returns `nil`, and every
  `load_*` helper has a non-map fallback clause. Nothing crashes for an anonymous
  viewer.
- **`sidebar_open?/1` in the browser template** reads only the assign, with no DB
  query in render.
- **Etcher/Fresco/Tessera pins.** Etcher `~> 0.14.0` accepts fresco 0.12, and the
  CDN URLs in `phoenix_kit.js` match the locked versions.
