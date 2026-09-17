defmodule PhoenixKit.Modules.Storage.ReferenceDeletionTest do
  @moduledoc """
  `delete_file_completely/1` deletes a stored object exactly when no
  remaining instance row references its key.

  It used to decide per file: when any other file shared the directory, it
  deleted nothing at all. That kept a cross-user copy's shared bytes, but it
  also kept everything else in that directory forever — a system-managed
  child's objects (tile chunks, an edited image's backup) and any key only
  the deleted file used.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Users.Auth

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_ref_delete_#{n}")

    # Only this test's bucket: the seeded default one lives in the project
    # tree and outlasts the test.
    Repo.update_all(Bucket, set: [enabled: false])

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "ref-delete-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    %{n: n, alice: user!("alice", n), bob: user!("bob", n)}
  end

  defp user!(name, n) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-refdel-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp upload!(user, bytes) do
    path =
      Path.join(System.tmp_dir!(), "pk_ref_delete_src_#{System.unique_integer([:positive])}.txt")

    File.write!(path, bytes)
    checksum = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    result = Storage.store_file_in_buckets(path, "document", user.uuid, checksum, "txt", "a.txt")
    File.rm(path)

    case result do
      {:ok, file} -> file
      {:ok, file, _} -> file
    end
  end

  defp keys(file), do: file.uuid |> Storage.list_file_instances() |> Enum.map(& &1.file_name)

  defp exists?(key), do: Manager.file_exists?(key)

  test "a key another file still references stays; the last reference deletes it", ctx do
    original = upload!(ctx.alice, "shared bytes #{ctx.n}")
    copy = upload!(ctx.bob, "shared bytes #{ctx.n}")

    [key] = keys(original)
    assert keys(copy) == [key], "the cross-user copy shares the stored object"

    assert {:ok, _} = Storage.delete_file_completely(original)
    assert exists?(key)

    assert {:ok, _} = Storage.delete_file_completely(copy)
    refute exists?(key)
  end

  test "keys only the deleted file used go, even when its directory is shared", ctx do
    file = upload!(ctx.alice, "own bytes #{ctx.n}")
    [key] = keys(file)

    # A second file in the same directory with a key of its own — what an
    # edited image and its backup look like.
    neighbour_key = Path.join(file.file_path, "neighbour.txt")
    src = Path.join(System.tmp_dir!(), "pk_ref_delete_nb_#{ctx.n}.txt")
    File.write!(src, "neighbour")
    {:ok, _} = Manager.store_file(src, path_prefix: neighbour_key)

    {:ok, %{file: child}} =
      Storage.store_system_file(src, neighbour_key,
        parent_file_uuid: upload!(ctx.bob, "other #{ctx.n}").uuid,
        mime_type: "text/plain",
        file_type: "other"
      )

    assert child.file_path == file.file_path

    assert {:ok, _} = Storage.delete_file_completely(file)
    refute exists?(key), "the old rule skipped every deletion here"
    assert exists?(neighbour_key)
  end

  test "a file's system-managed children lose their objects with it", ctx do
    parent = upload!(ctx.alice, "parent #{ctx.n}")
    child_key = "_tiles/#{parent.uuid}/#{parent.uuid}.dzi"
    src = Path.join(System.tmp_dir!(), "pk_ref_delete_tile_#{ctx.n}.xml")
    File.write!(src, "<Image/>")

    {:ok, %{file: child}} =
      Storage.store_system_file(src, child_key,
        parent_file_uuid: parent.uuid,
        mime_type: "application/xml"
      )

    assert exists?(child_key)

    assert {:ok, _} = Storage.delete_file_completely(parent)
    refute exists?(child_key)
    refute Storage.get_file(child.uuid)
  end

  test "delete_stored_objects/1 decides again when it deletes", ctx do
    file = upload!(ctx.alice, "kept #{ctx.n}")
    [key] = keys(file)

    # A caller whose "nobody references it" is out of date by now.
    assert :ok = Storage.delete_stored_objects([key])
    assert exists?(key)

    assert :ok = Storage.delete_stored_objects([key], exclude_file_uuids: [file.uuid])
    refute exists?(key)
  end

  test "delete_file_data/1 keeps a key another file references", ctx do
    original = upload!(ctx.alice, "data #{ctx.n}")
    _copy = upload!(ctx.bob, "data #{ctx.n}")
    [key] = keys(original)

    assert :ok = Storage.delete_file_data(original)
    assert exists?(key)
  end
end
