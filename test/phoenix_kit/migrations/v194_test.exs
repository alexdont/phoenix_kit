defmodule PhoenixKit.Migrations.Postgres.V194Test do
  @moduledoc """
  V194 withholds the integration bodies the settings history already
  recorded, run against seeded activity entries.

  Until the writer learned to recognise integration rows, every connect and
  token refresh copied the row's whole JSON body — tokens included — into a
  permanent `setting.changed` entry. The suite's database is already past
  V194 and its writer no longer does this, so the entries are seeded the way
  the old writer wrote them, and the migration's real statements run against
  them (`up/1` and `down/1` execute exactly `up_statements/1` and
  `down_statements/1`).
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V194
  alias PhoenixKit.Test.Repo

  @token_body ~s({"access_token":"sk-live-secret","provider":"openai"})

  defp run_up, do: Enum.each(V194.up_statements("public."), &Repo.query!/1)
  defp run_down, do: Enum.each(V194.down_statements("public."), &Repo.query!/1)

  defp setting!(key, module) do
    uuid = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO phoenix_kit_settings (uuid, key, module, value_json) VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(uuid), key, module, %{"access_token" => "sk-live-secret"}]
    )

    uuid
  end

  # An entry as the old writer recorded it: both values in full.
  defp entry!(key, resource_uuid, metadata \\ %{}) do
    metadata =
      Map.merge(
        %{
          "key" => key,
          "from" => @token_body,
          "to" => String.replace(@token_body, "secret", "rotated"),
          "restricted" => false,
          "source" => "system"
        },
        metadata
      )

    %{rows: [[uuid]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_activities
          (action, mode, resource_type, resource_uuid, permanent, metadata)
        VALUES ('setting.changed', 'system', 'setting', $1, true, $2)
        RETURNING uuid
        """,
        [Ecto.UUID.dump!(resource_uuid), metadata]
      )

    uuid
  end

  defp metadata(entry_uuid) do
    %{rows: [[metadata]]} =
      Repo.query!("SELECT metadata FROM phoenix_kit_activities WHERE uuid = $1", [entry_uuid])

    metadata
  end

  defp withheld?(metadata) do
    metadata["from"] == nil and metadata["to"] == nil and metadata["restricted"] == true
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  test "an entry for a live integration row loses its values and keeps the rest" do
    uuid = Ecto.UUID.generate()
    # Integration rows are keyed by their own uuid, with module "integrations".
    Repo.query!(
      "INSERT INTO phoenix_kit_settings (uuid, key, module, value_json) VALUES ($1, $2, 'integrations', '{}')",
      [Ecto.UUID.dump!(uuid), uuid]
    )

    entry = entry!(uuid, uuid, %{"source" => "settings"})

    run_up()

    metadata = metadata(entry)
    assert withheld?(metadata)
    assert metadata["key"] == uuid, "which row changed is still recorded"
    assert metadata["source"] == "settings"
  end

  test "an entry for an integration row deleted since is recognised by its uuid key" do
    gone = Ecto.UUID.generate()
    entry = entry!(gone, gone)

    run_up()

    assert withheld?(metadata(entry))
  end

  test "a legacy integration: key is withheld, whatever row it points at" do
    row = setting!("integration:openai:default", "integrations")
    orphan = entry!("integration:anthropic:work", Ecto.UUID.generate())
    live = entry!("integration:openai:default", row)

    run_up()

    assert withheld?(metadata(orphan))
    assert withheld?(metadata(live))
  end

  test "a module-integrations row with any other key is withheld" do
    row = setting!("oddly_named_connection", "integrations")
    entry = entry!("oddly_named_connection", row)

    run_up()

    assert withheld?(metadata(entry))
  end

  test "ordinary settings keep their history" do
    row = setting!("site_url_v194_probe", "general")

    entry =
      entry!("site_url_v194_probe", row, %{
        "from" => "https://old.test",
        "to" => "https://new.test"
      })

    run_up()

    metadata = metadata(entry)
    assert metadata["from"] == "https://old.test"
    assert metadata["to"] == "https://new.test"
    assert metadata["restricted"] == false
  end

  test "other actions are never touched, even with an integration-shaped key" do
    gone = Ecto.UUID.generate()

    %{rows: [[uuid]]} =
      Repo.query!(
        """
        INSERT INTO phoenix_kit_activities (action, resource_uuid, metadata)
        VALUES ('integration.connected', $1, $2) RETURNING uuid
        """,
        [Ecto.UUID.dump!(gone), %{"key" => gone, "from" => "kept", "to" => "kept"}]
      )

    run_up()

    assert metadata(uuid)["from"] == "kept"
  end

  test "re-runnable: an entry already withheld is left exactly as it is" do
    gone = Ecto.UUID.generate()
    entry = entry!(gone, gone, %{"from" => nil, "to" => nil, "restricted" => true, "x" => 1})

    version = row_version(entry)
    run_up()

    assert row_version(entry) == version, "the row was not rewritten"
    assert metadata(entry)["x"] == 1
  end

  # A row's xmin changes whenever an UPDATE rewrites it, even to equal content.
  defp row_version(entry_uuid) do
    %{rows: [[xmin]]} =
      Repo.query!("SELECT xmin::text FROM phoenix_kit_activities WHERE uuid = $1", [entry_uuid])

    xmin
  end

  test "up stamps 194; down only moves the marker back" do
    gone = Ecto.UUID.generate()
    entry = entry!(gone, gone)

    run_up()
    assert marker() == "194"

    run_down()
    assert marker() == "193"
    assert withheld?(metadata(entry)), "the withheld values are not restored"
  end
end
