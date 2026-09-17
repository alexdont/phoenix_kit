defmodule PhoenixKitWeb.FileEditingServingTest do
  @moduledoc """
  How `FileController` serves files that can be edited after upload.

  An edit changes the bytes behind a permanent URL, so what a cache may keep
  is the whole question:

    * a URL with `?v=` (the served instance's checksum) names bytes: kept
      for good while it matches, redirected (never re-answered) when not;
    * a URL without one is kept for a day, or revalidated on every use once
      the file has been edited;
    * while an edit renders or after it failed, a placeholder nobody may
      keep — never the bytes the edit is hiding;
    * an edited image's unedited original is a system-managed file: never
      served by these routes, only by the authenticated `unedited` action;
    * deep-zoom tiles carry the version in their path.

  Skipped when ImageMagick isn't installed.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query
  import Plug.Test, only: [conn: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ApplyImageEditJob
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.FileController

  @moduletag :tmp_dir

  # ExUnit cannot skip from `setup` (a `skip:` it returns is only context), so
  # the ImageMagick check is a module tag. `convert`/`identify` are what
  # `ImageProcessor` runs — ImageMagick 6 has no `magick` binary.
  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  @buckets_cache :phoenix_kit_buckets_cache
  @job_worker "PhoenixKit.Modules.Storage.ApplyImageEditJob"

  setup %{tmp_dir: tmp} do
    if imagemagick?() do
      :persistent_term.erase(@buckets_cache)
      n = System.unique_integer([:positive])
      Repo.update_all(Bucket, set: [enabled: false])

      {:ok, _bucket} =
        Storage.create_bucket(%{
          name: "edit-serving-#{n}",
          provider: "local",
          endpoint: Path.join(tmp, "bucket"),
          enabled: true,
          priority: 0
        })

      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

      _first_user_is_owner = user!("first", n)
      owner = user!("owner", n)
      source = Path.join(tmp, "photo.jpg")

      {_, 0} =
        System.cmd("convert", [
          "-size",
          "30x40",
          "xc:red",
          "-size",
          "30x40",
          "xc:blue",
          "+append",
          source
        ])

      %{n: n, owner: owner, photo: upload!(owner, source), source: source}
    else
      {:ok, skip: true}
    end
  end

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp user!(name, n) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-editserve-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.get!(Auth.User, user.uuid)
  end

  defp upload!(user, path) do
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", user.uuid, sha, "jpg", "photo.jpg")

    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => "photo.jpg"}
      })

    Storage.get_file(file.uuid)
  end

  defp reload(file), do: Storage.get_file(file.uuid)

  # Saves `params` and runs the job, unless `run: false`.
  defp edit!(file, owner, params, opts \\ []) do
    {:ok, pending} = ImageEditing.edit(file, params, scope: Scope.for_user(owner))

    if Keyword.get(opts, :run, true) do
      for job <-
            Repo.all(
              from(j in Oban.Job, where: j.worker == @job_worker and j.state == "available")
            ) do
        Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
        :ok = ApplyImageEditJob.perform(%{job | attempt: 1})
      end

      reload(file)
    else
      pending
    end
  end

  defp instance(file, variant \\ "original"),
    do: Storage.get_file_instance_by_name(file.uuid, variant)

  defp show(file, variant \\ "original", opts \\ []) do
    params =
      %{
        "file_uuid" => file.uuid,
        "variant" => variant,
        "token" => URLSigner.generate_token(file.uuid, variant)
      }
      |> then(fn p -> if opts[:v], do: Map.put(p, "v", opts[:v]), else: p end)

    conn(:get, "/")
    |> then(fn c ->
      if opts[:etag], do: Plug.Conn.put_req_header(c, "if-none-match", opts[:etag]), else: c
    end)
    |> FileController.show(params)
  end

  defp header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

  describe "cache lifetime" do
    test "an unversioned URL of a never-edited file keeps for a day", ctx do
      conn = show(ctx.photo)

      assert conn.status == 200
      assert header(conn, "cache-control") == ["public, max-age=86400"]
      assert header(conn, "etag") == [~s("#{instance(ctx.photo).checksum}")]
    end

    test "a URL naming the current bytes keeps for good", ctx do
      v = URLSigner.version(instance(ctx.photo))

      for requested <- [v, String.slice(v, 0, 8), String.upcase(v)] do
        conn = show(ctx.photo, "original", v: requested)

        assert conn.status == 200
        assert header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      end
    end

    test "a URL naming other bytes is sent to the current ones", ctx do
      current = URLSigner.version(instance(ctx.photo))

      # `?v[a]=b` and `?v[]=...` arrive as a map and a list — stale, never a 500.
      for stale <- [
            "0123456789abcdef",
            "0123",
            "not-hex!",
            String.slice(current, 0, 7),
            %{"a" => "b"},
            [current]
          ] do
        conn = show(ctx.photo, "original", v: stale)

        assert conn.status == 302, "#{inspect(stale)} is not the current version"
        assert header(conn, "cache-control") == ["no-store"]

        assert header(conn, "location") == [
                 URLSigner.signed_url(ctx.photo.uuid, "original", version: current)
               ]
      end
    end

    test "a revalidation keeps the lifetime of its URL", ctx do
      etag = ~s("#{instance(ctx.photo).checksum}")
      v = URLSigner.version(instance(ctx.photo))

      assert %{status: 304} = conn = show(ctx.photo, "original", etag: etag)
      assert header(conn, "cache-control") == ["public, max-age=86400"]

      assert %{status: 304} = conn = show(ctx.photo, "original", etag: etag, v: v)
      assert header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "an edited file's unversioned URL is revalidated on every use", ctx do
      old = URLSigner.version(instance(ctx.photo))
      edited = edit!(ctx.photo, ctx.owner, %{"rotate" => 90})

      for variant <- ["original", "thumbnail"] do
        conn = show(edited, variant)
        assert conn.status == 200
        assert header(conn, "cache-control") == ["public, no-cache"]
        assert header(conn, "etag") == [~s("#{instance(edited, variant).checksum}")]
      end

      # Its old versioned URL now names bytes it no longer serves.
      assert show(edited, "original", v: old).status == 302
    end

    test "a stand-in for a missing variant is never kept, versioned or not", ctx do
      thumb = instance(ctx.photo, "thumbnail")
      {:ok, _} = Storage.delete_file_instance(thumb)

      for opts <- [[], [v: URLSigner.version(thumb)]] do
        conn = show(ctx.photo, "thumbnail", opts)
        assert conn.status == 200
        assert header(conn, "cache-control") == ["no-store"]
        assert header(conn, "x-variant-status") == ["pending"]
      end
    end
  end

  describe "while an edit renders" do
    test "every variant is a placeholder nobody keeps", ctx do
      pending = edit!(ctx.photo, ctx.owner, %{"rotate" => 90}, run: false)
      v = URLSigner.version(instance(ctx.photo))

      for {variant, opts} <- [{"original", []}, {"original", [v: v]}, {"thumbnail", []}] do
        conn = show(pending, variant, opts)

        assert conn.status == 200
        assert header(conn, "content-type") |> hd() =~ "image/svg+xml"
        assert header(conn, "cache-control") == ["no-store"]
        assert header(conn, "cdn-cache-control") == ["no-store"]
        assert header(conn, "x-variant-status") == ["editing"]
        refute conn.resp_body =~ "JFIF"
      end
    end

    test "a failed edit stays a placeholder", ctx do
      pending = edit!(ctx.photo, ctx.owner, %{"rotate" => 90}, run: false)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^pending.uuid),
        set: [edit_state: "failed"]
      )

      conn = show(reload(pending))
      assert header(conn, "x-variant-status") == ["edit-failed"]
      assert header(conn, "cache-control") == ["no-store"]
    end

    test "the token is still checked first", ctx do
      pending = edit!(ctx.photo, ctx.owner, %{"rotate" => 90}, run: false)

      conn =
        FileController.show(conn(:get, "/"), %{
          "file_uuid" => pending.uuid,
          "variant" => "original",
          "token" => "zzzz"
        })

      assert conn.status == 401
    end
  end

  describe "the unedited original" do
    setup ctx do
      edited = edit!(ctx.photo, ctx.owner, %{"rotate" => 90})
      %{edited: edited, backup: ImageEditing.backup(edited)}
    end

    defp api_conn(user) do
      conn(:get, "/")
      |> Plug.Conn.put_private(:phoenix_endpoint, PhoenixKitWeb.Endpoint)
      |> Plug.Conn.assign(:phoenix_kit_current_user, user)
    end

    defp unedited(file_uuid, user, params \\ %{}) do
      user
      |> api_conn()
      |> FileController.unedited(Map.put(params, "file_uuid", file_uuid))
    end

    # The query of a link from `FileController.unedited_url/4`.
    defp link_params(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    test "is never served by the public route", ctx do
      for variant <- ["original", "thumbnail"] do
        assert show(ctx.backup, variant).status == 404
      end
    end

    test "downloads for whoever may edit the file", ctx do
      admin = user!("admin", ctx.n)
      {:ok, _} = Roles.assign_role(admin, "Admin")

      for user <- [ctx.owner, Repo.get!(Auth.User, admin.uuid)] do
        conn = unedited(ctx.edited.uuid, user)

        assert conn.status == 200
        assert conn.resp_body == File.read!(ctx.source)
        assert header(conn, "cache-control") == ["private, no-store"]

        assert header(conn, "content-disposition") == [
                 ~s|attachment; filename="photo (unedited).jpg"|
               ]
      end
    end

    test "is a 404 for anyone else, and for a file with none", ctx do
      stranger = user!("stranger", ctx.n)
      other = upload!(stranger, ctx.source)

      assert unedited(ctx.edited.uuid, stranger).status == 404
      assert unedited(other.uuid, stranger).status == 404
      assert unedited(ctx.backup.uuid, ctx.owner).status == 404
      assert unedited(Ecto.UUID.generate(), ctx.owner).status == 404
      assert unedited(ctx.edited.uuid, nil).status == 401
    end

    test "a signed link works for the user it was made for, for an hour", ctx do
      stranger = user!("stranger", ctx.n)
      other = user!("other", ctx.n)
      url = FileController.unedited_url(PhoenixKitWeb.Endpoint, ctx.edited.uuid, stranger.uuid)
      params = link_params(url)

      conn = unedited(ctx.edited.uuid, stranger, params)
      assert conn.status == 200
      assert conn.resp_body == File.read!(ctx.source)

      assert unedited(ctx.edited.uuid, other, params).status == 404
      assert unedited(ctx.edited.uuid, nil, params).status == 401

      # Made for another file.
      elsewhere =
        FileController.unedited_url(PhoenixKitWeb.Endpoint, Ecto.UUID.generate(), stranger.uuid)

      assert unedited(ctx.edited.uuid, stranger, link_params(elsewhere)).status == 404

      # Too old.
      stale =
        Phoenix.Token.sign(
          PhoenixKitWeb.Endpoint,
          "phoenix_kit unedited original",
          {ctx.edited.uuid, stranger.uuid},
          signed_at: System.system_time(:second) - 3601
        )

      assert unedited(ctx.edited.uuid, stranger, %{"t" => stale}).status == 404
      assert unedited(ctx.edited.uuid, stranger, %{"t" => "forged"}).status == 404
      assert FileController.unedited_url(PhoenixKitWeb.Endpoint, ctx.edited.uuid, nil) == nil
    end

    test "a preview variant is served inline", ctx do
      url =
        FileController.unedited_url(PhoenixKitWeb.Endpoint, ctx.edited.uuid, ctx.owner.uuid,
          variant: "thumbnail"
        )

      conn = unedited(ctx.edited.uuid, ctx.owner, link_params(url))
      thumbnail = Storage.get_file_instance_by_name(ctx.backup.uuid, "thumbnail")

      assert conn.status == 200
      assert byte_size(conn.resp_body) == thumbnail.size
      assert [~s|inline; filename="photo (unedited).jpg"|] = header(conn, "content-disposition")
      assert header(conn, "cache-control") == ["private, no-store"]

      # A variant it never had falls back to the original.
      conn = unedited(ctx.edited.uuid, ctx.owner, %{"variant" => "poster"})
      assert conn.resp_body == File.read!(ctx.source)
    end

    test "is announced by the info endpoint, which never describes it", ctx do
      admin = user!("admin", ctx.n)
      {:ok, _} = Roles.assign_role(admin, "Admin")
      admin = Repo.get!(Auth.User, admin.uuid)

      info =
        ctx.owner
        |> api_conn()
        |> FileController.info(%{"file_uuid" => ctx.edited.uuid})
        |> Map.fetch!(:resp_body)
        |> Jason.decode!()

      assert info["edited"] == true
      assert info["unedited_url"] =~ "/api/files/#{ctx.edited.uuid}/unedited?t="

      for variant <- info["variants"] do
        assert variant["url"] =~ "?v="
      end

      backup_info = admin |> api_conn() |> FileController.info(%{"file_uuid" => ctx.backup.uuid})

      assert backup_info.status == 404
    end

    test "has no public URL", ctx do
      assert Storage.get_public_url(ctx.backup) == nil
      assert Storage.get_public_url_by_variant(ctx.backup, "thumbnail") == nil
    end
  end

  describe "URL builders" do
    test "carry the served instance's version", ctx do
      original = instance(ctx.photo)
      v = URLSigner.version(original)

      assert URLSigner.signed_url(ctx.photo.uuid, "original", version: original) ==
               URLSigner.signed_url(ctx.photo.uuid, "original") <> "?v=" <> v

      assert URLSigner.signed_url(ctx.photo.uuid, "original", version: nil) ==
               URLSigner.signed_url(ctx.photo.uuid, "original")

      assert Storage.get_public_url(ctx.photo) =~ "?v=#{v}"

      assert Enum.all?(Storage.list_image_set_variants(ctx.photo.uuid), &(&1.url =~ "?v="))
    end

    test "leave the version off while an edit renders", ctx do
      pending = edit!(ctx.photo, ctx.owner, %{"rotate" => 90}, run: false)

      url = Storage.get_public_url(pending)
      assert url
      refute url =~ "?v="
    end
  end

  describe "deep-zoom tiles" do
    # Tessera cuts tiles with ImageMagick 7's `magick`; 6 alone can't.
    unless System.find_executable("magick"),
      do: @describetag(skip: "ImageMagick 7 (magick) is not installed")

    setup do
      {:ok, _} = Settings.update_setting("storage_tile_generation_enabled", "true")
      :ok
    end

    defp token(file), do: URLSigner.generate_token(file.uuid, "dzi")

    defp manifest(file, stem) do
      FileController.serve_manifest(conn(:get, "/"), %{
        "token" => token(file),
        "dzi_filename" => "#{stem}.dzi"
      })
    end

    defp tile(file, stem) do
      FileController.serve_tile(conn(:get, "/"), %{
        "token" => token(file),
        "files_segment" => "#{stem}_files",
        "level" => "0",
        "tile_filename" => "0_0.jpg"
      })
    end

    defp tile_keys(file) do
      file.uuid
      |> Storage.list_system_children()
      |> Enum.reject(&ImageEditing.backup?/1)
      |> Enum.map(& &1.file_name)
    end

    test "the manifest URL names the version", ctx do
      v = URLSigner.version(instance(ctx.photo))

      urls =
        URLSigner.put_dzi_url(%{}, ctx.photo.uuid, "image/jpeg", version: instance(ctx.photo))

      assert urls["dzi"] =~ "/tiles/#{token(ctx.photo)}/#{ctx.photo.uuid}-#{v}.dzi"

      assert URLSigner.put_dzi_url(%{}, ctx.photo.uuid, "image/jpeg")["dzi"] =~
               "/#{ctx.photo.uuid}.dzi"
    end

    test "are stored and cached under their version", ctx do
      v = URLSigner.version(instance(ctx.photo))
      stem = "#{ctx.photo.uuid}-#{v}"

      conn = manifest(ctx.photo, stem)
      assert conn.status == 200
      assert header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert conn.resp_body =~ ~s(Width="60")

      conn = tile(ctx.photo, stem)
      assert conn.status == 200
      assert header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

      assert Enum.sort(tile_keys(ctx.photo)) ==
               Enum.sort([
                 "_tiles/#{ctx.photo.uuid}/#{v}/#{ctx.photo.uuid}.dzi",
                 "_tiles/#{ctx.photo.uuid}/#{v}/#{ctx.photo.uuid}_files/0/0_0.jpg"
               ])
    end

    test "a tile whose object went missing is cut again", ctx do
      stem = "#{ctx.photo.uuid}-#{URLSigner.version(instance(ctx.photo))}"
      assert tile(ctx.photo, stem).status == 200

      [key] = tile_keys(ctx.photo) |> Enum.filter(&String.ends_with?(&1, ".jpg"))
      :ok = Manager.delete_file(key)

      assert tile(ctx.photo, stem).status == 200
      assert Manager.file_exists?(key)
    end

    test "the legacy unversioned form is the current version, never kept", ctx do
      assert %{status: 200} = conn = manifest(ctx.photo, ctx.photo.uuid)
      assert header(conn, "cache-control") == ["no-store"]

      assert %{status: 200} = conn = tile(ctx.photo, ctx.photo.uuid)
      assert header(conn, "cache-control") == ["no-store"]
    end

    test "an edit moves them to a new version and drops the old ones", ctx do
      old = "#{ctx.photo.uuid}-#{URLSigner.version(instance(ctx.photo))}"
      assert tile(ctx.photo, old).status == 200

      edited = edit!(ctx.photo, ctx.owner, %{"rotate" => 90})
      new = "#{edited.uuid}-#{URLSigner.version(instance(edited))}"

      assert tile_keys(edited) == [], "the old version's tiles went with the edit"
      assert manifest(edited, old).status == 404
      assert tile(edited, old).status == 404

      assert %{status: 200} = conn = manifest(edited, new)
      assert conn.resp_body =~ ~s(Width="40")
      assert tile(edited, new).status == 200
    end

    test "none while an edit renders, and none for a hidden file", ctx do
      edited = edit!(ctx.photo, ctx.owner, %{"rotate" => 90})
      backup = ImageEditing.backup(edited)
      pending = edit!(edited, ctx.owner, %{"rotate" => 180}, run: false)
      v = URLSigner.version(instance(pending))

      assert manifest(pending, "#{pending.uuid}-#{v}").status == 404
      assert tile(pending, "#{pending.uuid}-#{v}").status == 404
      assert manifest(pending, pending.uuid).status == 404

      backup_v = URLSigner.version(instance(backup))
      assert manifest(backup, "#{backup.uuid}-#{backup_v}").status == 404
      assert tile(backup, backup.uuid).status == 404
    end
  end
end
