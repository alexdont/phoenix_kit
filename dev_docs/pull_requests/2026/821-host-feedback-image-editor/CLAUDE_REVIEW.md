# PR #821 — Host-feedback sweep and image editor

**Author:** mdon (`main`) · **Merged:** 2026-09-17 · **Reviewed:** 2026-09-17 (post-merge)

31 commits, 137 files: module-declared Oban queues, variant caching and job
dedupe, check-only auth `require` hooks, `Settings.subscribe/0`, chart lanes and
`ChartScale`, the locale-in-URL contract, doctor probes, V193–V195, and the image
editor (`ImageEdit`, `ImageEditing`, `ApplyImageEditJob`, versioned file URLs,
reference-based object deletion, the `ImageEditor` component).

## Verdict

Ship it. Most of the PR holds up under a close read:

- the settings miss-fill race fix closes every ordering we walked
- the auth hook split moves each old `ensure_*` body unchanged, and a
  `require` hook without its mount hook raises rather than letting anyone in
- V193–V195 are prefix-safe
- the lock ordering in the edit pipeline (file row, then path locks) has no
  cycle
- reference-counted deletion handles every shared-key case

The review found two high-severity bugs (the uploader's extension picked
ImageMagick's coder in the edit job; a redaction left the unredacted image at
its public bucket URL) and five medium ones. All are fixed and covered by tests. It also found that **the PR's image-editing test suites never
actually ran**: two probed for ImageMagick 7's `magick`, and all four "skipped"
from `setup`, which ExUnit does not honour. With that fixed they all pass, except
the 6 deep-zoom tile tests, which skip without ImageMagick 7 (see below).

Released in 2.28.0; the public-bucket fix in 2.28.1.

## Findings

### BUG - HIGH — the edit job let the uploader's extension choose ImageMagick's coder (FIXED)

`ApplyImageEditJob.render/2` named its source and output temp files
`pk_edit_N.#{file.ext}`. `file.ext` comes from the upload's filename, and
editability only checks the claimed `mime_type`, which the browser supplies. So
`x.mvg` uploaded as `image/png` was editable, and saving any edit ran `identify`
and `convert` on `/tmp/pk_edit_N.mvg`. ImageMagick then read the file as MVG,
which can pull server files into the rendered image the user views (or reach
Ghostscript via `.ps`), depending on the host's `policy.xml`. The variant
pipeline was already protected (`Manager.temp_extension/1`); the new job went
around it.

**Fix:** the source temp copy keeps its extension only through
`Manager.temp_extension/1`. The output's extension comes from the MIME type,
which must be on the editable allowlist (`output_extension/1`). Test: "the
uploader's extension never picks ImageMagick's coder".

### BUG - MEDIUM — a discarded run failed a newer save's revision (FIXED)

Oban emits `[:oban, :job, :exception]` with `state: :discard` for a final-attempt
error or timeout. The handler, and the last-attempt `rescue`, then marked the
file's **current** revision failed. The unique config deliberately ignores an
executing job, so a save (or Retry) that lands while a run executes gets a run
of its own. The old run failing then put the newer revision on the failed
placeholder, and the newer run found nothing pending and stopped.

**Fix:** `mark_current_failed/3` does nothing while another apply run for the
file is queued or executing (queried with the configured prefix). Tests: "a
discarded run leaves a save that landed meanwhile to its own run". The existing
timeout test now uses a real job row.

### BUG - MEDIUM — a failed edit's Retry from a stale view could undo a newer edit (FIXED)

`ImageEditing.retry/2` re-saved `file.edits` from the caller's struct, which is
the LiveView's assign. If another tab had since saved a redaction, Retry from
the older tab wrote the old edit back as a new revision and published
unredacted pixels.

**Fix:** `start(file, :current)` reads the edit, and the "is there anything to
retry" check, from the row it locks. Test: "a retry from a stale view re-renders
the saved edit, not the one it showed".

### BUG - MEDIUM — `mix phoenix_kit.doctor` always said `site_url` is not set (FIXED)

`check_sitemap_serving/0` read `Settings.get_setting("site_url", "")`, but the
doctor turns on `update_mode` before starting the app, and in that mode every
settings read returns the default. So every install got the "site_url is not
set" warning, plus a false "localhost answers 503 in production" note in dev.

**Fix:** it reads through the doctor's existing SQL helper
`configured_site_url(prefix)`, as `host_flavor/1` already did.

### BUG - MEDIUM — the switcher's session-locale warning could never reach a host (FIXED)

The warning was compiled under `if Mix.env() == :dev`. Mix compiles dependencies
in `:prod` whatever the host runs, so only phoenix_kit's own dev build had it,
and the moduledoc and `guides/locale-routing.md` promise hosts a warning they
never got. Once it could fire, `session_locale_page?/2` would also have flagged
every default-language host page outside the kit's mount: it compared
`Routes.path`'s prefixed URL (`/phoenix_kit/products`) with the raw path
(`/products`).

**Fix:** the check runs at runtime (`Mix.env/0` only when Mix is loaded, so a
release never warns), and it compares both sides without the mount prefix. Test
(integration): "a host page outside the mount is judged without the mount
prefix".

### BUG - MEDIUM — the doctor's pooler check passed PgBouncer on 6432 (FIXED)

When the config looked like a pooler but the probe found no transaction pooling,
the check now passed. The probe can only prove pooling: an idle PgBouncer
(`server_round_robin = 0`, LIFO) hands both probe statements the same backend,
so a real transaction-mode PgBouncer read as "not detected". That dropped both
the `@disable_ddl_transaction` advice and the Postgres-notifier hint.

**Fix:** that case warns again, says the probe cannot clear an idle pooler, and
keeps both hints. `Repair.Environment.pooled?/2` was unaffected.

### BUG - HIGH — redaction on a public bucket left the unredacted image at its public URL (FIXED in 2.28.1)

On a first edit the original's instance rows moved to the hidden backup, but
the objects stayed at their keys. On a public bucket `Manager.get_file_access/1`
answers with `{:redirect, bucket_url}`, so before the edit every viewer had
been sent to the raw object URL of the original and each variant
(`…/<md5>_original.jpg`). Those objects stayed world-readable after a
redaction, so anyone holding a saved link, a log line or an archived page
still got the unredacted image. The "never served by the public routes" claim
only covered PhoenixKit's own routes.

**Fix:** `ApplyImageEditJob.prepare/1` copies every unedited object to a
private key (`unedited_<128 random bits>_<name>`, same directory). The swap
then does three things under the file-row lock:

- points each backup row and its locations at its copy
- starts over if a row has no copy (for example, a variant generated
  meanwhile)
- queues the served keys for `delete_stored_objects/2`, which keeps a key
  another file still references (a cross-user copy)

Unused copies are released after publish and deleted on discard. A backup
made by 2.28.0 moves on its next edit. After a revert, the next edit copies
again, because the rows were served in between. The tests assert the old keys
are gone and the copy holds the original bytes: three fail on the 2.28.0 job.

**What remains, documented in the storage README:** responses already cached.
A versioned URL is `immutable`, so a CDN or browser that fetched the unedited
image keeps it until its own cache expires. Hosts behind a CDN should purge on
`[:phoenix_kit, :storage, :file_edited]` telemetry, which carries
`removed_keys`.

### IMPROVEMENT - HIGH — the PR's image-editing tests never ran (FIXED)

- `file_editing_serving_test.exs` and `image_editor_test.exs` probed
  `magick -version`. `ImageProcessor` runs `convert`/`identify`, so on
  ImageMagick 6 (the review sandbox) the probe failed. `image_editor_test` did not
  rescue it, so the probe raised `:enoent`.
- All four files returned `{:ok, skip: true}` from `setup`. That only adds
  context, it skips nothing, so the tests ran without their fixtures.

Result: the baseline had 42 failures across the two files, which looked like
environment noise.

**Fix:** a compile-time `@moduletag skip:` when `convert`/`identify` are missing,
and `identify` as the runtime probe. The deep-zoom tile describe block also
skips without `magick`: Tessera's tile generator requires ImageMagick 7
(`Tessera.TileGenerator.ensure_magick/0`), so on an IM6-only host editing works
but deep zoom does not. Worth knowing for deploy images.

### IMPROVEMENT - MEDIUM — `MediaBrowser.open_image_editor` skipped the viewer's gates, and queried in render (FIXED)

The event takes a client-supplied uuid. It checked scope and `editable?` but not
`UUIDUtils.valid?` (a malformed uuid raises in the cast and crashes the
LiveView) or the `only_file_type` lock. The template also built
`Scope.for_user/1` (role and permission queries) as a component attribute, so on
every re-render of the modal block. **Fix:** reuse `fetch_viewable_file/2`, and
build the editor scope once when the editor opens.

### IMPROVEMENT - MEDIUM — soft-failure paths missed `catch :exit` (FIXED)

c557aaba made `migrated_version_runtime/1` survive a dead pool, but
`Install.Common.database_reachable?/0` and `try_direct_database_version_check/1`
then query that same pool with only `rescue`, so `mix phoenix_kit.update` still
crashed. Both catch `:exit` now.

### NITPICK — fixed along the way

- `?v[a]=b` on a file URL was a 500 (`to_string/1` on a map). A non-string `v`
  is now a stale version and redirects. Covered in the stale-version test.
- `History.secret_key_now?/1` failed **open**: a failed `module` lookup fell
  back to the key-name rule, which cannot recognise an integration row's uuid
  key. It now returns `true` (withheld), and catches `:exit` too.
- `Settings.Events` docs claimed other nodes' caches drop their copy "when the
  cache hears of the change". Nothing does that: they serve the old value until
  the five-minute TTL. The docs now say so.
- The magic-link registration page's title was an untranslated literal, and it
  is now the whole tab title.

### Not fixed — on record

- **IMPROVEMENT - HIGH — `MediaBrowser` gives system-level edit rights to anyone
  who can see an in-scope file.** It passes `authorized={true}`, matching rotate
  and delete ("the host decided who sees the browser"). For editing, that power
  includes **Restore** (undoes someone else's redaction everywhere),
  `delete_unedited`, and a signed link to the unedited original. In an embed
  like a warehouse module, any user of that module can therefore see the
  unredacted image. This is a product decision, not a slip: the alternative
  (`ImageEditing.can_edit?` — owner, Owner/Admin, `media` permission) would lock
  embedded browsers out of editing their own module's files. **A host that
  treats redaction as a privacy control should gate the browser (or pass
  `scope`-based authorization) until core grows a per-embed `can_edit` option.**
- **BUG - MEDIUM (pre-existing since V184) — settings history stores
  name-marked secrets.** The broadcast withholds keys whose names contain
  `secret`/`password`/`token`; `History.record` only withholds restricted keys
  and integration rows (e.g. sibling `sync_incoming_password`, and
  `document_creator_google_oauth`'s cleanup write records the old tokens as
  `from`). Widening it hides audit values for harmless keys like `*_token_expiry`
  and needs a data migration for existing rows; left for a focused change
  (module-registered secret keys is the better shape).
- **IMPROVEMENT - MEDIUM — the image editor loses its EXIF quarter-turn size fix
  on any server reload** (`load/3` resets `:size`; the hook only reports on
  `src` change). Stretch until the next image load. Needs a hook change plus a
  browser check.
- **IMPROVEMENT - MEDIUM — file serving efficiency.**
  - A private-bucket revalidation downloads the whole object before answering
    304.
  - A variant that can never exist (auto-generation off, broken tooling)
    re-enqueues a full `ProcessFileJob` per view once the previous run
    completes. Same as the old `Task.start`, but no longer "one job per file".
  - Every tile request takes a `FOR SHARE` row lock even when the tile is
    stored.
- **IMPROVEMENT - MEDIUM — `ObanConfig` can't read single-line queue lists**
  (`queues: [default: 10, mailers: 20]`): every declared queue is reported
  missing and none is added. Predates the PR; the PR widened the set of queues it
  checks.
- **IMPROVEMENT - MEDIUM — `goto_home` and `guides/locale-routing.md` assume
  `url_prefix: "/"`.** With a `/phoenix_kit` mount the home link is
  `/phoenix_kit/fr`, which is consistent with every other switcher link but 404s
  for host pages. Worth a sentence in the guide.
- **IMPROVEMENT - MEDIUM — `{:phoenix_kit_require, :admin}` on a host view**
  swaps in the kit's admin layout and becomes Owner-only (no permission mapping),
  exactly as `ensure_admin` always did. The new docs invite hosts to use it;
  they should point host pages at `{:module, key}` / `:authenticated`.
- **NITPICK**
  - `ChartScale.fraction/2` and `percent/2` raise on `Decimal` input despite the
    moduledoc.
  - The boot queue check only looks at an Oban instance named `Oban`.
  - The cache generation counter resets on a cache restart. The race window is
    theoretical.
  - Save-as-copy leaves a deduped result unlinked (`edited_from_uuid`).
  - The upload path writes content-addressed keys without the delete protocol's
    path lock.
  - Settings broadcasts now reach `phoenix_kit:settings` subscribers that
    have no catch-all `handle_info` (noted in the CHANGELOG).

## Validation

- `mix precommit`: clean (compile, credo --strict, dialyzer, 137 JS tests).
  `language_switcher.ex` joins `.dialyzer_ignore.exs` for its runtime
  `Mix.env/0` check.
- Full `mix test` against PostgreSQL: **63 doctests, 5574 tests, 0 failures,
  6 skipped**. Before these fixes the same run had 43 failures: 42 from the
  broken ImageMagick probe/skip, plus the known `integrations_test`
  `refute_receive` flake.
- Image-editing suites (render, `ImageEditing`, serving, `ImageEditor` UI) run
  for real on ImageMagick 6. The 6 deep-zoom tile tests skip without
  ImageMagick 7.
