defmodule PhoenixKit.Modules.Storage.UploadWithoutObanTest do
  @moduledoc """
  An upload stands when its variant job cannot be queued.

  Variant generation is best-effort by design, and every enqueue goes through
  `Storage.queue_variant_generation/3`, which logs and answers `:error`. The
  new-file path used to call `Oban.insert/1` itself, so with no Oban instance
  running (a host that runs none on this node, a misconfigured one) the
  upload raised after the file was already stored — which is why the other
  storage tests start Oban just to store a file. This one does not.
  """

  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_upload_no_oban_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "upload-no-oban-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{
        "email" => "upload-no-oban-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    source = Path.join(System.tmp_dir!(), "pk_upload_no_oban_#{n}.txt")
    File.write!(source, "bytes #{n}")

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm(source)
    end)

    %{user: user, source: source}
  end

  test "a new file is stored and the failed enqueue is only logged", %{user: user, source: source} do
    refute Oban.whereis(Oban), "this test needs no Oban instance running"
    checksum = :sha256 |> :crypto.hash(File.read!(source)) |> Base.encode16(case: :lower)

    log =
      capture_log(fn ->
        assert {:ok, file} =
                 Storage.store_file_in_buckets(
                   source,
                   "document",
                   user.uuid,
                   checksum,
                   "txt",
                   "notes.txt"
                 )

        send(self(), {:stored, file})
      end)

    assert_received {:stored, file}
    assert Storage.get_file(file.uuid)
    assert log =~ "Could not enqueue variant generation for #{file.uuid}"
  end

  test "the helper answers :error instead of raising", %{user: user} do
    log =
      capture_log(fn ->
        assert Storage.queue_variant_generation(%{uuid: Ecto.UUID.generate()}, user.uuid, "x") ==
                 :error
      end)

    assert log =~ "Could not enqueue variant generation"
  end
end
