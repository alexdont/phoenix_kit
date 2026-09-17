defmodule PhoenixKitWeb.FileController do
  @moduledoc """
  File serving controller with signed URL support.

  Handles secure file retrieval with token-based authentication and cache headers.
  """
  use PhoenixKitWeb, :controller

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{ImageEditing, Manager, TesseraAdapter, URLSigner}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Routes

  @doc """
  Serve a file variant by ID with signed URL token.

  ## Request

      GET /file/:file_uuid/:variant/:token

  ## Parameters

  - `file_uuid`: UUID of the file
  - `variant`: Variant name (e.g., "original", "thumbnail", "medium")
  - `token`: Signed token for authentication

  ## Response

  Success (200):
  - File streamed to client with appropriate headers:
    - `Cache-Control: public, max-age=31536000, immutable` (1 year)
    - `ETag: "md5-hash"`
    - `Content-Type: <mime-type>`
    - `Content-Disposition: inline; filename="..."`

  Not Modified (304):
  - Returned when request includes `If-None-Match` matching the file ETag

  Error (401):
      "Invalid or expired token"

  Error (404):
      "File or variant not found"
  """
  def show(conn, %{"file_uuid" => file_uuid, "variant" => variant, "token" => token} = params) do
    with {:ok, file} <- get_servable_file(file_uuid),
         :ok <- verify_token(file_uuid, variant, token) do
      if ImageEditing.edit_in_progress?(file) do
        serve_edit_placeholder(conn, file)
      else
        serve_variant(conn, file, variant, params["v"])
      end
    else
      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> text("Invalid or expired token")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("File or variant not found")
    end
  end

  # `requested_version` is the URL's `v`. A versioned URL names content: it
  # is served (and cached for good) only while it names the bytes the variant
  # holds now; any other version is redirected to the current one, never
  # answered with different bytes under the same URL.
  defp serve_variant(conn, file, variant, requested_version) do
    with {:ok, instance, freshness} <- get_file_instance(file.uuid, variant),
         :ok <- check_version(instance, freshness, requested_version),
         result <- get_file_access(instance) do
      cache = cache_mode(file, freshness, requested_version)

      case result do
        {:local, file_path} ->
          serve_file(conn, file, instance, file_path, cache)

        {:redirect, url} ->
          # A pending variant redirects to the ORIGINAL's storage URL. The
          # redirect itself must not be cached, or the client keeps following
          # it to the full-size image after the variant exists; nor may an
          # unversioned one for an edited file, whose object key changes with
          # every edit. (The object's own headers are the bucket's business.)
          conn
          |> put_redirect_cache_headers(cache)
          |> redirect(external: url)

        {:proxy, file_name} ->
          proxy_remote_file(conn, file, instance, file_name, cache)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> text("File or variant not found")

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> text("Error retrieving file: #{inspect(reason)}")
      end
    else
      {:stale_version, instance} ->
        current = URLSigner.signed_url(file.uuid, variant, version: instance, locale: :none)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> redirect(to: current)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("File or variant not found")
    end
  end

  defp check_version(_instance, _freshness, nil), do: :ok
  defp check_version(_instance, :pending, _requested), do: :ok

  # Any hex prefix of 8+ characters names the bytes (older links carry an
  # 8-character `v`); the canonical form is `URLSigner.version/1`'s 16.
  defp check_version(instance, :exact, requested) when is_binary(requested) do
    requested = String.downcase(requested)

    if byte_size(requested) >= 8 and requested =~ ~r/\A[0-9a-f]+\z/ and
         String.starts_with?(String.downcase(instance.checksum || ""), requested),
       do: :ok,
       else: {:stale_version, instance}
  end

  # `?v[a]=b` arrives as a map: not a version of anything, so stale.
  defp check_version(instance, :exact, _requested), do: {:stale_version, instance}

  @doc false
  # How long a response may be kept:
  #
  #   * `:pending` — a stand-in for a variant not generated yet: never.
  #   * `:immutable` — a versioned URL naming the current bytes: for good.
  #   * `:revalidate` — an unversioned URL of an edited file: its bytes have
  #     changed before and can again, so every use is checked (a 304 is cheap).
  #   * `:day` — an unversioned URL of a file never edited: one day, then a
  #     check. Not `immutable`: a lifetime that long could not be taken back
  #     if the image is edited (or redacted) later.
  def cache_mode(_file, :pending, _requested), do: :pending
  def cache_mode(_file, :exact, requested) when is_binary(requested), do: :immutable
  def cache_mode(%{edit_revision: revision}, :exact, _) when revision > 0, do: :revalidate
  def cache_mode(_file, :exact, _requested), do: :day

  # A file that must never be served here: an edited image's hidden unedited
  # backup, a tile chunk (served by the tile routes), or nothing at all.
  defp get_servable_file(file_uuid) do
    case Storage.get_file(file_uuid) do
      %{system_managed: true} -> {:error, :not_found}
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  # While an edit renders (or after it failed) the file's old bytes are the
  # very thing the edit may be hiding: answer a neutral placeholder that no
  # cache may keep.
  @edit_placeholder ~s(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 3"><rect width="4" height="3" fill="#d4d4d8"/></svg>)

  defp serve_edit_placeholder(conn, file) do
    status = if file.edit_state == "failed", do: "edit-failed", else: "editing"

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("cdn-cache-control", "no-store")
    |> put_resp_header("x-variant-status", status)
    |> put_resp_content_type("image/svg+xml")
    |> send_resp(200, @edit_placeholder)
  end

  @doc """
  Get file information without serving the file.

  ## Request

      GET /api/files/:file_uuid/info

  ## Response

  Success (200):
      {
        "file_uuid": "uuid",
        "original_filename": "photo.jpg",
        "mime_type": "image/jpeg",
        "file_type": "image",
        "size": 1234567,
        "status": "active",
        "variants": [
          {
            "variant_name": "original",
            "mime_type": "image/jpeg",
            "size": 1234567,
            "width": 1920,
            "height": 1080,
            "url": "/file/uuid/original/token"
          }
        ]
      }
  """
  def info(conn, %{"file_uuid" => file_uuid}) do
    with {:ok, user} <- require_user(conn.assigns[:phoenix_kit_current_user]),
         {:ok, file} <- get_servable_file(file_uuid),
         {:ok, file} <- authorize_file_read(file, user) do
      info_response(conn, file, user)
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "UNAUTHORIZED", message: "Authentication required"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "FILE_NOT_FOUND", message: "File not found"})
    end
  end

  @unedited_salt "phoenix_kit unedited original"
  @unedited_max_age 3600

  @doc """
  Downloads an edited image's unedited original.

  ## Request

      GET /api/files/:file_uuid/unedited[?t=<token>][&variant=<name>]

  Only for a signed-in user who may edit the file
  (`ImageEditing.can_edit?/2`: its owner, an Owner/Admin, or a holder of the
  `"media"` permission) — or who holds a link from `unedited_url/4`, made for
  them within the last hour by a host that decided they may manage the file.
  Anyone else, and a file with no unedited original, gets the same 404.

  `variant` (a variant the original had, e.g. `"large"`) is served inline,
  for a preview; without it the original is an attachment. Nothing here may
  be cached: the unedited bytes are what an edit (a redaction) may hide.
  """
  def unedited(conn, %{"file_uuid" => file_uuid} = params) do
    with {:ok, user} <- require_user(conn.assigns[:phoenix_kit_current_user]),
         {:ok, file} <- get_servable_file(file_uuid),
         :ok <- authorize_unedited(conn, file, user, params["t"]),
         %{} = backup <- ImageEditing.backup(file) || {:error, :not_found},
         {:ok, instance, disposition} <- unedited_instance(backup, params["variant"]) do
      send_unedited(conn, file, instance, disposition)
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> text("Authentication required")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("File not found")
    end
  end

  @doc """
  A link to `file_uuid`'s unedited original (see `unedited/2`) that works
  for the signed-in user `user_uuid` for an hour, whether or not
  `ImageEditing` would let them edit the file on its own. Hand it out only
  where that decision has been made — the image editor does.

  `context` is what `Phoenix.Token` signs with: a conn, a LiveView socket or
  an endpoint. `variant:` links a preview-sized variant instead. `nil`
  without a user.
  """
  @spec unedited_url(term(), String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def unedited_url(context, file_uuid, user_uuid, opts \\ [])

  def unedited_url(_context, _file_uuid, nil, _opts), do: nil

  def unedited_url(context, file_uuid, user_uuid, opts) do
    token = Phoenix.Token.sign(context, @unedited_salt, {file_uuid, user_uuid})

    query =
      case Keyword.get(opts, :variant) do
        nil -> [t: token]
        variant -> [t: token, variant: variant]
      end

    Routes.path("/api/files/#{file_uuid}/unedited", locale: :none) <>
      "?" <> URI.encode_query(query)
  end

  defp authorize_unedited(conn, file, user, token) do
    cond do
      ImageEditing.can_edit?(file, Scope.for_user(user)) -> :ok
      valid_unedited_token?(conn, token, file.uuid, user.uuid) -> :ok
      true -> {:error, :not_found}
    end
  end

  defp valid_unedited_token?(conn, token, file_uuid, user_uuid) when is_binary(token) do
    Phoenix.Token.verify(conn, @unedited_salt, token, max_age: @unedited_max_age) ==
      {:ok, {file_uuid, user_uuid}}
  rescue
    # No endpoint to verify with (a bare conn): no token is valid.
    _ -> false
  end

  defp valid_unedited_token?(_conn, _token, _file_uuid, _user_uuid), do: false

  defp unedited_instance(backup, variant) when variant in [nil, "", "original"] do
    case Storage.get_file_instance_by_name(backup.uuid, "original") do
      nil -> {:error, :not_found}
      instance -> {:ok, instance, "attachment"}
    end
  end

  # A preview: the variant when the original had it, else the original.
  defp unedited_instance(backup, variant) when is_binary(variant) do
    case Storage.get_file_instance_by_name(backup.uuid, variant) do
      nil ->
        with {:ok, instance, _} <- unedited_instance(backup, nil), do: {:ok, instance, "inline"}

      instance ->
        {:ok, instance, "inline"}
    end
  end

  defp unedited_instance(_backup, _variant), do: {:error, :not_found}

  defp send_unedited(conn, file, instance, disposition) do
    temp_path =
      Path.join(System.tmp_dir!(), "phoenix_kit_unedited_#{System.unique_integer([:positive])}")

    try do
      case Manager.retrieve_file(instance.file_name, destination_path: temp_path) do
        {:ok, _} ->
          conn
          |> put_resp_header("cache-control", "private, no-store")
          |> put_resp_header("x-content-type-options", "nosniff")
          |> put_resp_header(
            "content-disposition",
            ~s(#{disposition}; filename="#{unedited_filename(file)}")
          )
          |> put_resp_content_type(instance.mime_type)
          |> send_file(200, temp_path)

        {:error, reason} ->
          Logger.warning(
            "[FileController] unedited original #{instance.file_name} unreadable: #{inspect(reason)}"
          )

          conn
          |> put_status(:not_found)
          |> text("File not found")
      end
    after
      File.rm(temp_path)
    end
  end

  # `photo.jpg` → `photo (unedited).jpg`, with nothing that could break out
  # of the quoted header value.
  defp unedited_filename(file) do
    ext = Path.extname(file.original_file_name)

    "#{Path.basename(file.original_file_name, ext)} (unedited)#{ext}"
    |> String.replace(~r/[\x00-\x1f"\\]/, "_")
  end

  @doc """
  Requires an authenticated caller for the info endpoint. It lives in the
  unauthenticated `[:browser, :phoenix_kit_auto_setup]` scope, so this is the
  gate: before it, any visitor got file metadata and a freshly-minted signed URL
  for any uuid, which handed out capability URLs the signing scheme exists to
  withhold (issue #687 class).
  """
  @spec require_user(term()) :: {:ok, User.t()} | {:error, :no_user}
  def require_user(%User{} = user), do: {:ok, user}
  def require_user(_), do: {:error, :no_user}

  @doc """
  Authorizes a file-info read. The owner (`file.user_uuid`) or an Owner/Admin may
  read; everyone else — and a missing file — is `{:error, :not_found}`, the
  *same* result, so the endpoint is not a file-existence oracle.

  The staff bypass is `Scope.system_role?/1` (Owner/Admin), NOT
  `can_access_admin_area?/1`: a holder of a single module permission must not be
  able to read every other user's file metadata and signed variant URLs.
  """
  @spec authorize_file_read(term(), User.t()) :: {:ok, map()} | {:error, :not_found}
  def authorize_file_read(nil, _user), do: {:error, :not_found}

  def authorize_file_read(%{user_uuid: owner} = file, %User{uuid: uuid} = user) do
    if owner == uuid or Scope.system_role?(Scope.for_user(user)) do
      {:ok, file}
    else
      {:error, :not_found}
    end
  end

  defp info_response(conn, file, user) do
    file_uuid = file.uuid
    instances = Storage.list_file_instances(file_uuid)

    variant_urls =
      Enum.map(instances, fn instance ->
        url = URLSigner.signed_url(file_uuid, instance.variant_name, version: instance)

        %{
          variant_name: instance.variant_name,
          mime_type: instance.mime_type,
          size: instance.size,
          width: instance.width,
          height: instance.height,
          url: url
        }
      end)

    json(conn, %{
      file_uuid: file.uuid,
      original_filename: file.original_file_name,
      mime_type: file.mime_type,
      file_type: file.file_type,
      size: file.size,
      status: file.status,
      variants: variant_urls,
      edited: ImageEditing.edited?(file),
      edit_state: file.edit_state,
      # Only for someone who may edit the file: the link is a grant of its own.
      unedited_url:
        if(ImageEditing.edited?(file) and ImageEditing.can_edit?(file, Scope.for_user(user)),
          do: unedited_url(conn, file_uuid, user.uuid)
        )
    })
  end

  @doc """
  Serve the DZI manifest for an image, generating it lazily if it doesn't
  exist yet.

  ## Request

      GET /tiles/:token/:dzi_filename

  where `dzi_filename` is `"<file_uuid>-<version>.dzi"` (`version` as in
  `URLSigner.version/1`, of the file's original) and `token` is the signed
  per-file token from `URLSigner.generate_token(file_uuid, "dzi")`.
  Returns the XML manifest describing the image's dimensions and tile
  config — Tessera's `generate_manifest/3` produces it on first request,
  subsequent requests serve from storage.

  The version is in the path, not a query string, because the viewer derives
  tile URLs from the manifest's path. Tiles are cut from one version of the
  image and stored under it, so an edit never serves new tiles under an old
  URL (or old ones under a new URL): a version that is not the current one is
  a 404, and so is every tile request while an edit is rendering. The legacy
  unversioned `"<file_uuid>.dzi"` resolves to the current version and is not
  cached.

  The token gates BOTH manifest and tile generation: without it, the
  endpoint is a 404. The MediaBrowser emits manifest URLs only when
  `storage_tile_generation_enabled` is on, so unauthenticated callers
  can't trigger lazy ImageMagick work by guessing UUIDs.
  """
  def serve_manifest(conn, %{"token" => token, "dzi_filename" => filename}) do
    with true <- tile_generation_enabled?(),
         {:ok, file_uuid, requested} <- parse_manifest_filename(filename),
         :ok <- verify_tile_token(file_uuid, token),
         {:ok, source} <- tile_source(file_uuid, requested),
         :ok <- ensure_manifest_cached(source),
         {:ok, body} <- read_tile_storage(source.base <> ".dzi") do
      conn
      |> put_resp_header("cache-control", tile_cache_control(requested))
      |> put_resp_content_type("application/xml")
      |> send_resp(200, body)
    else
      false -> send_resp(conn, 404, "Tile generation disabled")
      :error -> send_resp(conn, 404, "Not found")
      {:error, reason} -> tile_error(conn, reason)
    end
  end

  @doc """
  Serve a single DZI tile, generating it lazily if it doesn't exist yet.

  ## Request

      GET /tiles/:token/:files_segment/:level/:tile_filename

  where `token` is the signed per-file token (same one used by
  `serve_manifest/2`), `files_segment` is `"<file_uuid>-<version>_files"`
  (or the legacy `"<file_uuid>_files"`),
  `level` is the integer zoom level, and `tile_filename` is
  `"<col>_<row>.<ext>"`. This matches the layout Tessera writes to
  storage and the URL convention OpenSeadragon derives from a DZI
  manifest's base URL (token in the path survives that derivation;
  query-string tokens don't).
  """
  def serve_tile(conn, %{
        "token" => token,
        "files_segment" => files_segment,
        "level" => level,
        "tile_filename" => tile_filename
      }) do
    with true <- tile_generation_enabled?(),
         {:ok, file_uuid, requested, tile} <-
           parse_tile_path(files_segment, level, tile_filename),
         :ok <- verify_tile_token(file_uuid, token),
         {:ok, source} <- tile_source(file_uuid, requested),
         {level_int, col, row, ext} = tile,
         key = "#{source.base}_files/#{level_int}/#{col}_#{row}.#{ext}",
         :ok <- ensure_tile_cached(source, tile, key),
         {:ok, body} <- read_tile_storage(key) do
      conn
      |> put_resp_header("cache-control", tile_cache_control(requested))
      |> put_resp_content_type(content_type_for(ext))
      |> send_resp(200, body)
    else
      false -> send_resp(conn, 404, "Tile generation disabled")
      :error -> send_resp(conn, 404, "Not found")
      {:error, reason} -> tile_error(conn, reason)
    end
  end

  # Single per-file token authorizes both the manifest and every tile
  # derived from it. Uses the same URLSigner pattern as the standard
  # `/file/:file_uuid/:variant/:token` route (`signed_url/3` →
  # `verify_token/3`); the "dzi" variant name is distinct from the
  # storage variants ("original" / "small" / "medium" / "large") so a
  # leaked file-serving token doesn't grant tile access and vice versa.
  defp verify_tile_token(file_uuid, token) do
    if URLSigner.verify_token(file_uuid, "dzi", token) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp tile_generation_enabled? do
    PhoenixKit.Settings.get_setting("storage_tile_generation_enabled", "false") == "true"
  end

  # A versioned manifest or tile never changes; an unversioned one is the
  # current version of whatever the file holds, so it is never kept.
  defp tile_cache_control(nil), do: "no-store"
  defp tile_cache_control(_version), do: "public, max-age=31536000, immutable"

  # The image tiles are cut from, at the version the URL asks for (`nil`:
  # the current one). Everything a tile needs comes from one consistent
  # read of the file and its original (the file row held FOR SHARE, which
  # an edit's swap needs FOR UPDATE): `base` (the storage key stem, carrying
  # the version — the original instance's, as in the URLs), the dimensions,
  # and the checksum the source object must have.
  defp tile_source(file_uuid, requested) do
    with {:ok, {file, original}} <- tile_snapshot(file_uuid),
         :ok <- ensure_image(file),
         :ok <- ensure_not_editing(file),
         version when is_binary(version) <- URLSigner.version(original),
         :ok <- ensure_version(requested, version),
         {:ok, w, h} <- ensure_dimensions(file) do
      {:ok,
       %{
         file_uuid: file_uuid,
         checksum: original.checksum,
         width: w,
         height: h,
         base: "#{file_uuid}/#{version}/#{file_uuid}"
       }}
    else
      nil -> {:error, :not_found}
      other -> other
    end
  end

  defp tile_snapshot(file_uuid) do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      file =
        repo.one(
          from(f in Storage.File,
            where: f.uuid == ^file_uuid and f.system_managed == false,
            lock: "FOR SHARE"
          )
        )

      original = file && Storage.get_file_instance_by_name(file_uuid, "original")

      if file && original, do: {file, original}, else: repo.rollback(:not_found)
    end)
  end

  defp ensure_not_editing(file) do
    if ImageEditing.edit_in_progress?(file), do: {:error, :not_found}, else: :ok
  end

  defp ensure_version(nil, _current), do: :ok
  defp ensure_version(current, current), do: :ok
  defp ensure_version(_requested, _current), do: {:error, :not_found}

  # ---------------------------------------------------------------------------
  # Tile / manifest helpers
  # ---------------------------------------------------------------------------

  # `<uuid>-<version>` or the legacy bare `<uuid>` (version `nil`).
  @tile_stem ~S"([0-9a-f-]{36})(?:-([0-9a-f]{16}))?"

  defp parse_manifest_filename(filename) do
    case Regex.run(~r/^#{@tile_stem}\.dzi$/, filename) do
      [_, uuid] -> {:ok, uuid, nil}
      [_, uuid, version] -> {:ok, uuid, version}
      _ -> :error
    end
  end

  defp parse_tile_path(files_segment, level, tile_filename) do
    with [_, uuid | version] <- Regex.run(~r/^#{@tile_stem}_files$/, files_segment),
         {level_int, ""} <- Integer.parse(level),
         [_, col_str, row_str, ext] <-
           Regex.run(~r/^(\d+)_(\d+)\.(jpg|png)$/, tile_filename),
         {col, ""} <- Integer.parse(col_str),
         {row, ""} <- Integer.parse(row_str) do
      {:ok, uuid, List.first(version), {level_int, col, row, ext}}
    else
      _ -> :error
    end
  end

  defp ensure_image(%{mime_type: "image/" <> _}), do: :ok
  defp ensure_image(_), do: {:error, :not_an_image}

  defp ensure_dimensions(%{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: {:ok, w, h}

  defp ensure_dimensions(_), do: {:error, :missing_dimensions}

  # Serialize concurrent first-request generators for the same manifest /
  # tile. Without `with_tile_lock`, two browser tabs racing the cold path
  # both spawn ImageMagick. The lock is keyed per source file so different
  # images stay parallel. Double-checked locking: re-test `file_exists?`
  # inside the lock so the loser of the race short-circuits to the cached
  # file the winner just wrote.

  defp ensure_manifest_cached(source) do
    destination = TesseraAdapter.destination_for(source.base <> ".dzi")

    if Manager.file_exists?(destination) do
      :ok
    else
      with_tile_lock(source.file_uuid, fn ->
        generate_manifest_if_missing(source, destination)
      end)
    end
  end

  defp generate_manifest_if_missing(source, destination) do
    if Manager.file_exists?(destination) do
      :ok
    else
      Tessera.generate_manifest({source.width, source.height}, source.base,
        storage: TesseraAdapter,
        storage_opts: [parent_file_uuid: source.file_uuid, mime_type: "application/xml"]
      )
    end
  end

  defp ensure_tile_cached(source, tile, key) do
    destination = TesseraAdapter.destination_for(key)

    if Manager.file_exists?(destination) do
      :ok
    else
      with_tile_lock(source.file_uuid, fn ->
        generate_tile_if_missing(source, tile, destination)
      end)
    end
  end

  defp generate_tile_if_missing(source, tile, destination) do
    if Manager.file_exists?(destination) do
      :ok
    else
      generate_tile_from_original(source, tile)
    end
  end

  # `:global.set_lock/3` is cluster-aware and lighter-weight than a
  # named GenServer for this access pattern (briefly-held cold-path
  # serialization). Lock retries every 50ms up to 50× = ~2.5s before
  # giving up — past that the request returns `:lock_timeout` and the
  # client retries naturally on the next viewer interaction.
  defp with_tile_lock(file_uuid, fun) do
    lock_id = {{__MODULE__, :tessera_lock, file_uuid}, self()}

    if :global.set_lock(lock_id, [node()], 50) do
      try do
        fun.()
      after
        :global.del_lock(lock_id, [node()])
      end
    else
      {:error, :lock_timeout}
    end
  end

  # The tile is stored under the version `source` names, so it is cut only
  # from bytes with that checksum: an original swapped by an edit since the
  # snapshot was read is not this version's source.
  defp generate_tile_from_original(source, {level, col, row, ext}) do
    case Storage.get_file_instance_by_name(source.file_uuid, "original") do
      nil ->
        {:error, :original_missing}

      %{checksum: checksum} when checksum != source.checksum ->
        {:error, :not_found}

      instance ->
        temp_path =
          Path.join(System.tmp_dir!(), "tessera-src-#{System.unique_integer([:positive])}")

        try do
          case Manager.retrieve_file(instance.file_name, destination_path: temp_path) do
            {:ok, _} ->
              Tessera.generate_tile(
                temp_path,
                {level, col, row},
                source.base,
                image_width: source.width,
                image_height: source.height,
                format: format_atom(ext),
                storage: TesseraAdapter,
                storage_opts: [
                  parent_file_uuid: source.file_uuid,
                  mime_type: content_type_for(ext),
                  metadata: %{"level" => level, "col" => col, "row" => row}
                ]
              )

            {:error, _} = err ->
              err
          end
        after
          # Cleanup runs even if Tessera.generate_tile/4 or Manager.retrieve_file/2
          # raises mid-flight. Without this, repeated failures leak files into
          # `System.tmp_dir!()` until inode exhaustion.
          File.rm(temp_path)
        end
    end
  end

  defp read_tile_storage(key) do
    destination = TesseraAdapter.destination_for(key)
    temp_path = Path.join(System.tmp_dir!(), "tessera-read-#{System.unique_integer([:positive])}")

    try do
      case Manager.retrieve_file(destination, destination_path: temp_path) do
        {:ok, _} ->
          {:ok, File.read!(temp_path)}

        {:error, _} = err ->
          err
      end
    after
      File.rm(temp_path)
    end
  end

  defp content_type_for("jpg"), do: "image/jpeg"
  defp content_type_for("png"), do: "image/png"

  defp format_atom("jpg"), do: :jpg
  defp format_atom("png"), do: :png

  defp tile_error(conn, :not_found) do
    send_resp(conn, 404, "Not found")
  end

  # The token check fails *closed* with 404 (not 401/403) so an attacker
  # probing UUIDs can't distinguish "file exists but token is wrong"
  # from "no such file" — both look identical from outside.
  defp tile_error(conn, :unauthorized) do
    send_resp(conn, 404, "Not found")
  end

  defp tile_error(conn, :not_an_image) do
    send_resp(conn, 415, "Unsupported media type")
  end

  defp tile_error(conn, :missing_dimensions) do
    send_resp(conn, 422, "Image dimensions not available")
  end

  defp tile_error(conn, :invalid_coordinate) do
    send_resp(conn, 404, "Tile out of range")
  end

  # Source `original` instance is missing — the tile pipeline can't
  # generate anything. Surface as 404 (the user-visible state matches
  # "this tile doesn't exist") rather than 500.
  defp tile_error(conn, :original_missing) do
    send_resp(conn, 404, "Source image missing")
  end

  # Cold-path lock contention — the cluster-wide lock held by another
  # writer didn't release within ~2.5s. Tell the client to back off; the
  # next viewer interaction will retry naturally.
  defp tile_error(conn, :lock_timeout) do
    conn
    |> put_resp_header("retry-after", "2")
    |> send_resp(503, "Tile generation in progress, retry")
  end

  defp tile_error(conn, reason) do
    Logger.warning("[Tessera tile] error: #{inspect(reason)}")
    send_resp(conn, 500, "Tile generation failed")
  end

  # Returns `{:ok, instance, :exact}` for the variant that was asked for, and
  # `{:ok, instance, :pending}` when that variant does not exist yet and the
  # ORIGINAL is served in its place. The caller must keep the two apart: a
  # stand-in served under the variant's own URL may never be cached, or every
  # browser and CDN pins the full-size image at the thumbnail URL (the variant
  # URL is deterministic, so the entry is reused for as long as it lives).
  @doc false
  def get_file_instance(file_uuid, variant) do
    case Storage.get_file_instance_by_name(file_uuid, variant) do
      nil ->
        # Variant doesn't exist, try to get the original to queue generation
        case Storage.get_file_instance_by_name(file_uuid, "original") do
          nil ->
            {:error, :not_found}

          original_instance ->
            queue_missing_variant(file_uuid, original_instance)
            # Return the original for now
            {:ok, original_instance, :pending}
        end

      instance ->
        {:ok, instance, :exact}
    end
  end

  # Enqueue generation for a file whose variant was requested before it existed.
  #
  # Inline, not in a `Task`: the payload is one local insert, and a detached
  # task inherits the caller's DB connection — under the test sandbox that
  # surfaces as "DBConnection owner exited" in the host's logs long after the
  # request is done. `ProcessFileJob` is unique while incomplete, so the insert
  # itself is the "already requested?" check and a gallery page full of missing
  # thumbnails enqueues one job, not one per image.
  #
  # Best-effort by design: an upload (or a view) must not fail because Oban is
  # down, so both a raise and an exit are swallowed with a warning.
  defp queue_missing_variant(file_uuid, original_instance) do
    case Storage.get_file(file_uuid) do
      nil ->
        :error

      file ->
        Storage.queue_variant_generation(file, file.user_uuid, original_instance.file_name)
    end
  rescue
    error ->
      Logger.warning("[FileController] could not enqueue variant generation: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[FileController] could not enqueue variant generation: #{inspect(reason)}")
      :error
  end

  defp verify_token(file_uuid, variant, token) do
    if URLSigner.verify_token(file_uuid, variant, token) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  # Get file access info with retry logic for bucket cache race conditions
  # Returns {:local, path} | {:redirect, url} | {:proxy, file_name} | {:error, reason}
  defp get_file_access(instance) do
    get_file_access_with_retry(instance, 5)
  end

  defp get_file_access_with_retry(instance, retries) do
    case Manager.get_file_access(instance.file_name) do
      {:local, _} = result ->
        result

      {:redirect, _} = result ->
        result

      {:proxy, _} = result ->
        result

      {:error, :not_found} when retries > 1 ->
        # Race condition during bucket cache init - retry with delay
        Logger.debug(
          "[FileController] File not found, retrying (#{retries - 1} left): #{instance.file_name}"
        )

        Process.sleep(100)
        get_file_access_with_retry(instance, retries - 1)

      error ->
        error
    end
  end

  # Serve a local file with proper headers.
  #
  # `freshness` is `:exact` for the variant that was requested and `:pending`
  # when the original stands in for a variant that has not been generated yet.
  # A stand-in carries neither an ETag nor a cache lifetime: it is the wrong
  # bytes for this URL, and the URL is permanent. Sending the original's ETag
  # would be worse still — a later conditional request for the real variant
  # would match it and get a 304 for an image the client never received.
  defp serve_file(conn, file, instance, file_path, :pending) do
    conn
    |> put_variant_cache_headers(instance, :pending)
    |> put_resp_header(
      "content-disposition",
      ~s(inline; filename="#{file.original_file_name}")
    )
    |> put_resp_content_type(instance.mime_type)
    |> send_file(200, file_path)
  end

  defp serve_file(conn, file, instance, file_path, cache) do
    etag = ~s("#{instance.checksum}")

    if etag in Plug.Conn.get_req_header(conn, "if-none-match") do
      conn
      |> put_variant_cache_headers(instance, cache)
      |> send_resp(304, "")
    else
      conn
      |> put_variant_cache_headers(instance, cache)
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="#{file.original_file_name}")
      )
      |> put_resp_content_type(instance.mime_type)
      |> send_file(200, file_path)
    end
  end

  @doc false
  # The cache policy for a file response, in one place because getting it wrong
  # is expensive in both directions: a stand-in cached for a year pins the
  # full-size original at a thumbnail's permanent URL, while dropping the long
  # lifetime from real variants would re-download every image on every view.
  def put_variant_cache_headers(conn, _instance, :pending) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-variant-status", "pending")
  end

  # `:exact` is the long lifetime a versioned URL gets.
  def put_variant_cache_headers(conn, instance, :exact),
    do: put_variant_cache_headers(conn, instance, :immutable)

  def put_variant_cache_headers(conn, instance, mode) do
    control =
      case mode do
        :immutable -> "public, max-age=31536000, immutable"
        :day -> "public, max-age=86400"
        :revalidate -> "public, no-cache"
      end

    conn
    |> put_resp_header("cache-control", control)
    |> put_resp_header("etag", ~s("#{instance.checksum}"))
  end

  # A redirect to a storage URL: never kept for a stand-in or an edited file
  # (both point somewhere else soon); otherwise left to the browser default.
  defp put_redirect_cache_headers(conn, :pending) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-variant-status", "pending")
  end

  defp put_redirect_cache_headers(conn, :revalidate),
    do: put_resp_header(conn, "cache-control", "no-store")

  defp put_redirect_cache_headers(conn, _cache), do: conn

  # Proxy a remote file through the server (for private buckets)
  defp proxy_remote_file(conn, file, instance, file_name, cache) do
    temp_path =
      Path.join(System.tmp_dir!(), "phoenix_kit_#{instance.uuid}_#{:rand.uniform(1_000_000)}")

    case Manager.retrieve_file(file_name, destination_path: temp_path) do
      {:ok, _} ->
        conn = serve_file(conn, file, instance, temp_path, cache)
        File.rm(temp_path)
        conn

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> text("File or variant not found")
    end
  end
end
