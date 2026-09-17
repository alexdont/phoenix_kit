defmodule PhoenixKit.Migrations.Postgres.V195 do
  @moduledoc """
  V195: image editing.

  An edited image keeps its uuid — every module that stored it keeps
  pointing at it — and its original instance becomes the edited bytes. The
  unedited original moves to a hidden, system-managed child file, so the
  owner can restore or delete it but nobody else can reach it. These columns
  record that on `phoenix_kit_files`:

    * `edits` (jsonb) — the current edit (`PhoenixKit.Modules.Storage.ImageEdit`),
      always applied to the unedited original
    * `edit_revision` (integer, default 0) — bumped by every save and revert,
      so a job can tell whether its snapshot is still the one wanted
    * `edit_state` (varchar(16)) — nil, "pending" or "failed"; while it is
      set the file is served as a placeholder, never as the old bytes
    * `original_file_uuid` — on an edited file, its hidden unedited backup
    * `edited_from_uuid` — on a "save as copy" result, the file it came from

  Both references are `ON DELETE SET NULL`: the backup's own lifecycle
  follows `parent_file_uuid` (cascade), and a copy outlives its source.

  It also indexes `phoenix_kit_file_instances.file_name`: a stored object is
  now deleted only when no instance row still references its key, and that
  check runs on every deletion.

  Additive only; re-runnable.
  """

  use Ecto.Migration

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V195 back: drops the columns and the index. Edits are lost; files keep their current bytes."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. `prefix` is the
  # bare schema name.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS edits jsonb",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS edit_revision integer NOT NULL DEFAULT 0",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS edit_state character varying(16)",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS original_file_uuid uuid",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS edited_from_uuid uuid",
      fk_statement(prefix, "original_file_uuid"),
      fk_statement(prefix, "edited_from_uuid"),
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_files_original_file_uuid_index
      ON #{p}phoenix_kit_files USING btree (original_file_uuid)
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_files_edited_from_uuid_index
      ON #{p}phoenix_kit_files USING btree (edited_from_uuid)
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_file_instances_file_name_index
      ON #{p}phoenix_kit_file_instances USING btree (file_name)
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '195'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "DROP INDEX IF EXISTS #{p}phoenix_kit_file_instances_file_name_index",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS edited_from_uuid",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS original_file_uuid",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS edit_state",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS edit_revision",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS edits",
      "COMMENT ON TABLE #{p}phoenix_kit IS '194'"
    ]
  end

  # The existence check is anchored to the schema by name (prefix-safe rule:
  # never a `regclass` cast in an immediate check).
  defp fk_statement(prefix, column) do
    p = prefix_str(prefix)
    name = "phoenix_kit_files_#{column}_fkey"

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = 'phoenix_kit_files'
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_files ADD CONSTRAINT #{name} FOREIGN KEY (#{column}) REFERENCES #{p}phoenix_kit_files(uuid) ON DELETE SET NULL;
      END IF;
    END
    $$
    """
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
