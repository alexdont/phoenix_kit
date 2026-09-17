defmodule PhoenixKit.Migrations.Postgres.V195Test do
  @moduledoc """
  V195's image-editing columns, run as the real SQL: down removes them,
  up puts them back (re-runnable), the self-references null out when the
  file they name is deleted, and each direction stamps its marker.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V195
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  @columns ~w(edits edit_revision edit_state original_file_uuid edited_from_uuid)

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp columns do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'phoenix_kit_files'
          AND column_name = ANY($1)
        """,
        [@columns]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  defp file_name_index? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'phoenix_kit_file_instances_file_name_index'"
      )

    rows != []
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  test "down removes the columns and index, up restores them, and each stamps its marker" do
    run(V195.down_statements("public"))
    assert columns() == []
    refute file_name_index?()
    assert marker() == "194"

    run(V195.up_statements("public"))
    assert columns() == Enum.sort(@columns)
    assert file_name_index?()
    assert marker() == "195"
  end

  test "up is re-runnable" do
    run(V195.up_statements("public"))
    run(V195.up_statements("public"))
    assert columns() == Enum.sort(@columns)
  end

  test "a file's edit revision starts at 0, and its references null out on delete" do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "v195-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    insert = fn name, extra ->
      %{rows: [[uuid]]} =
        Repo.query!(
          """
          INSERT INTO phoenix_kit_files
            (original_file_name, file_name, mime_type, file_type, ext, file_checksum,
             user_file_checksum, size, status, user_uuid, inserted_at, updated_at #{extra.cols})
          VALUES ($1, $1, 'image/png', 'image', 'png', $1, $1, 1, 'active', $2, now(), now() #{extra.vals})
          RETURNING uuid
          """,
          [name, Ecto.UUID.dump!(user.uuid) | extra.args]
        )

      uuid
    end

    none = %{cols: "", vals: "", args: []}
    source = insert.("v195-source", none)
    ref = %{cols: ", original_file_uuid, edited_from_uuid", vals: ", $3, $3", args: [source]}
    target = insert.("v195-target", ref)

    %{rows: [[0]]} =
      Repo.query!("SELECT edit_revision FROM phoenix_kit_files WHERE uuid = $1", [target])

    Repo.query!("DELETE FROM phoenix_kit_files WHERE uuid = $1", [source])

    assert %{rows: [[nil, nil]]} =
             Repo.query!(
               "SELECT original_file_uuid, edited_from_uuid FROM phoenix_kit_files WHERE uuid = $1",
               [target]
             )
  end
end
