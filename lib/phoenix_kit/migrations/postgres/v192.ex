defmodule PhoenixKit.Migrations.Postgres.V192 do
  @moduledoc """
  V192: Widen `phoenix_kit_annotations_kind_check` for the new
  `"arrow"` kind.

  Etcher 0.13's single-arrow tool was exposed in the media viewer's
  toolbar (`media_canvas_viewer.html.heex`) without widening the CHECK
  constraint (or the schema's `@kinds`) to match — the THIRD time this
  exact regression has shipped, after `"marker"` (V130) and `"image"`
  (V157). Without this, drawing an arrow works, labelling it works, and
  the whole thing silently fails to persist across a reload — the
  changeset rejection is a [warning] in the log and nothing else.

  Idempotent: each `ADD CONSTRAINT` is preceded by `DROP CONSTRAINT
  IF EXISTS` on the same prefixed table.

  ## down/1 is conditional, by necessity

  Rolling back re-adds the *narrower* CHECK, and Postgres validates
  every existing row when a CHECK is added. So the rollback is only
  possible while no `kind = 'arrow'` annotation exists — once a user has
  drawn one, the old constraint is not a truthful description of the
  data and there is no correct way for a schema migration to assert it.

  `down/1` therefore checks first and raises a message naming the row
  count and the two ways forward, rather than letting the `ALTER` fail
  with an opaque `23514` mid-rollback. The alternatives were both worse:
  deleting or rewriting user annotations is data loss a rollback has no
  business performing, and `NOT VALID` would leave a constraint that
  lies about the rows already in the table.
  """

  use Ecto.Migration

  # The DROP IF EXISTS immediately before each ADD makes the re-add
  # unconditional and safe. A `pg_constraint` existence guard would be
  # wrong here: `conname` is unique per namespace, not globally, so on a
  # multi-prefix install it would match another prefix's identically
  # named constraint and skip the add — leaving this prefix's table with
  # no kind check at all.
  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker', 'image', 'arrow'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '192'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Runs before anything is queued, so no flush/1 is needed and no
    # half-applied DDL can be left behind when this raises.
    guard_no_arrow_annotations!(p)

    execute(
      "ALTER TABLE #{p}phoenix_kit_annotations DROP CONSTRAINT IF EXISTS phoenix_kit_annotations_kind_check"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_annotations
      ADD CONSTRAINT phoenix_kit_annotations_kind_check
      CHECK (kind IN ('rectangle', 'circle', 'polygon', 'freehand', 'callout', 'text', 'dimension', 'line', 'marker', 'image'))
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '191'")
  end

  defp guard_no_arrow_annotations!(p) do
    %{rows: [[count]]} =
      repo().query!("SELECT count(*) FROM #{p}phoenix_kit_annotations WHERE kind = 'arrow'")

    if count > 0 do
      raise """
      Cannot roll back V192: #{count} annotation(s) with kind = 'arrow' exist \
      in #{p}phoenix_kit_annotations.

      V192 widened phoenix_kit_annotations_kind_check to allow 'arrow'. Rolling \
      back re-adds the narrower CHECK, which Postgres validates against every \
      existing row — so these rows would make the ALTER fail regardless.

      To proceed, either:

        1. Remove or convert them first, e.g.
             DELETE FROM #{p}phoenix_kit_annotations WHERE kind = 'arrow';
           (or UPDATE ... SET kind = 'callout' to keep the geometry), then \
      re-run the rollback; or
        2. Stay on V192 — the widened CHECK is a superset of V191's and is \
      harmless to a host that no longer draws arrow annotations.
      """
    end
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
