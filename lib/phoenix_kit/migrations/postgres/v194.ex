defmodule PhoenixKit.Migrations.Postgres.V194 do
  @moduledoc """
  V194: withholds the integration connection bodies the settings history has
  already recorded.

  The settings history (V184, 2.16.0) writes a permanent `setting.changed`
  activity entry for every settings write, with the value before and after —
  except for restricted settings, whose values it withholds. It decided what
  was restricted by key name alone. Integration connection rows are keyed by
  their own uuid, and their JSON body holds the connection's tokens (in plain
  text when integration encryption is off), so every connect and every token
  refresh wrote the whole body into an entry that is never pruned and that the
  admin Activity page shows to anyone who can open it. A rotated or revoked
  token stayed readable there for good.

  The writer no longer does this (`PhoenixKit.Settings.secret_setting?/2`).
  This migration withholds what it already wrote, exactly as a restricted
  setting is recorded: `from` and `to` become null and `restricted` true. The
  rest of each entry — who, when, which row — stays, so the history still
  says that the connection changed.

  An entry belongs to an integration row when any of these holds:

    * its key is the row's own uuid (`metadata.key` equals the entry's
      `resource_uuid`) — only integration rows are keyed that way, and this
      still recognises rows deleted since;
    * its key has the legacy `integration:` prefix;
    * a settings row with that key has `module = 'integrations'`.

  Re-runnable: an entry already restricted is left alone.

  ## down/1

  Moves the version marker back and nothing else. The withheld values are
  gone on purpose; restoring them is the defect this version removes.
  """

  use Ecto.Migration

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> prefix_str() |> up_statements() |> Enum.each(&execute/1)
  end

  def down(opts) do
    opts
    |> Map.get(:prefix, "public")
    |> prefix_str()
    |> down_statements()
    |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, exposed so the migration test can run the
  # real SQL against seeded entries (a migration's `up/1` cannot run outside an
  # Ecto.Migrator runner). `p` is the schema prefix with its trailing dot.
  def up_statements(p) do
    [
      """
      UPDATE #{p}phoenix_kit_activities AS a
      SET metadata = a.metadata || '{"from": null, "to": null, "restricted": true}'::jsonb
      WHERE a.action = 'setting.changed'
        AND (a.metadata ->> 'restricted') IS DISTINCT FROM 'true'
        AND (
          a.metadata ->> 'key' = a.resource_uuid::text
          OR a.metadata ->> 'key' LIKE 'integration:%'
          OR EXISTS (
            SELECT 1 FROM #{p}phoenix_kit_settings AS s
            WHERE s.key = a.metadata ->> 'key' AND s.module = 'integrations'
          )
        )
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '194'"
    ]
  end

  @doc false
  def down_statements(p) do
    ["COMMENT ON TABLE #{p}phoenix_kit IS '193'"]
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
