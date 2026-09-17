defmodule PhoenixKitWeb.FileVariantFallbackTest do
  @moduledoc """
  What happens when a variant is asked for before it has been generated.

  The controller serves the ORIGINAL in its place, which is the right call — a
  thumbnail that renders late is better than a broken image. The danger is
  everything around it: the variant's URL is deterministic and permanent, so a
  stand-in served with the original's ETag and a year of `immutable` pins the
  full-size image at the thumbnail's address in every browser and CDN that sees
  it, long after the real thumbnail exists. These tests pin the two halves of
  the fix: the response says "do not store this", and one request per file
  enqueues one generation run rather than one per missing variant.
  """
  use PhoenixKit.DataCase, async: true

  import Plug.Test, only: [conn: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.FileController

  defp make_file_with_original do
    {:ok, user} =
      Auth.register_user(%{
        email: "variant_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    unique = System.unique_integer([:positive])

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "photo.jpg",
        file_name: "photo_#{unique}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "cs_#{unique}",
        user_file_checksum: "ucs_#{unique}",
        size: 1234,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        file_uuid: file.uuid,
        variant_name: "original",
        file_name: file.file_name,
        mime_type: "image/jpeg",
        ext: "jpg",
        size: 1234,
        checksum: "cs_#{unique}"
      })

    {file, instance}
  end

  describe "classifying the served instance" do
    test "an existing variant is exact" do
      {file, _original} = make_file_with_original()

      assert {:ok, instance, :exact} = FileController.get_file_instance(file.uuid, "original")
      assert instance.variant_name == "original"
    end

    test "a missing variant falls back to the original and says so" do
      {file, original} = make_file_with_original()

      # Oban is not running in this suite, so the enqueue is swallowed by the
      # controller's best-effort rescue — which is itself the contract: a view
      # must not fail because the job system is unavailable.
      assert {:ok, instance, :pending} =
               ExUnit.CaptureLog.with_log(fn ->
                 FileController.get_file_instance(file.uuid, "thumb")
               end)
               |> elem(0)

      assert instance.uuid == original.uuid, "the original stands in for the missing variant"
    end

    test "a file with no original at all is not found" do
      {file, original} = make_file_with_original()
      {:ok, _} = Storage.delete_file_instance(original)

      assert {:error, :not_found} = FileController.get_file_instance(file.uuid, "thumb")
    end
  end

  describe "cache headers" do
    setup do
      {_file, instance} = make_file_with_original()
      %{instance: instance, conn: conn(:get, "/")}
    end

    test "a pending stand-in may not be stored, and carries no validator", %{
      conn: conn,
      instance: instance
    } do
      conn = FileController.put_variant_cache_headers(conn, instance, :pending)

      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      assert Plug.Conn.get_resp_header(conn, "x-variant-status") == ["pending"]

      assert Plug.Conn.get_resp_header(conn, "etag") == [],
             "an ETag from the original would let a later request for the real variant 304"
    end

    test "the real variant keeps the long immutable lifetime", %{conn: conn, instance: instance} do
      conn = FileController.put_variant_cache_headers(conn, instance, :exact)

      assert Plug.Conn.get_resp_header(conn, "cache-control") ==
               ["public, max-age=31536000, immutable"]

      assert Plug.Conn.get_resp_header(conn, "etag") == [~s("#{instance.checksum}")]
      assert Plug.Conn.get_resp_header(conn, "x-variant-status") == []
    end
  end

  describe "generation is enqueued once per file" do
    test "the job is unique per file while it is still incomplete" do
      unique = ProcessFileJob.__opts__()[:unique]

      assert unique[:keys] == [:file_uuid],
             "the job regenerates every variant, so the file is the unit of work"

      refute :completed in unique[:states],
             "a finished run must not swallow a later request for a new variant"

      for state <- [:available, :scheduled, :executing, :retryable] do
        assert state in unique[:states], "#{state} is an in-flight run and must dedupe"
      end
    end
  end
end
