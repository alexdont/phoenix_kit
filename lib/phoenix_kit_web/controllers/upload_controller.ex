defmodule PhoenixKitWeb.UploadController do
  @moduledoc """
  File upload controller for handling multipart uploads.

  Accepts file uploads, validates them, and queues them for background processing.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Utils.Format

  @upload_config %{
    # 100MB max file size
    max_size: 100 * 1024 * 1024,
    allowed_types:
      ~w(image/jpeg image/png image/webp image/gif video/mp4 video/webm video/quicktime application/pdf)
  }

  @doc """
  Upload a file via multipart form.

  ## Request

      POST /api/upload

  ## Parameters

  - `file` (required): The file to upload (multipart/form-data)
  - `user_uuid` (optional): Override user UUID (admin only)

  ## Response

  Success (200):
      {
        "file_uuid": "uuidv7-string",
        "original_filename": "photo.jpg",
        "file_type": "image",
        "mime_type": "image/jpeg",
        "size": 1234567,
        "status": "processing",
        "message": "Upload successful, processing variants..."
      }

  Error (400):
      {
        "error": "INVALID_FILE_TYPE",
        "message": "File type not allowed"
      }

  Error (413):
      {
        "error": "FILE_TOO_LARGE",
        "message": "File size exceeds maximum allowed (100MB)"
      }
  """
  def create(conn, params) do
    current_user = conn.assigns[:phoenix_kit_current_user]

    # Authorize BEFORE the upload is processed: an unauthenticated request is
    # refused without the server hashing, storing or enqueuing a job for it.
    # (Plug has already parsed the multipart body and spooled the temp file by
    # the time this runs, so the ordering saves the work, not the bandwidth.)
    #
    # Rate-limit the AUTHENTICATED UPLOADER, never the attributed owner: an
    # admin override attributes the file to someone else, and keying the limit
    # on that someone else would give the uploader a fresh window per victim
    # uuid. `resolve_upload_user/2` returning {:ok, _} guarantees a %User{}, so
    # `current_user.uuid` is safe.
    with {:ok, owner_uuid} <- resolve_upload_user(current_user, params),
         :ok <- RateLimiter.check_upload_rate_limit(current_user.uuid),
         {:ok, upload} <- extract_upload(params),
         :ok <- validate_file_type(upload),
         :ok <- validate_file_size(upload),
         {:ok, file_uuid} <- process_upload(upload, owner_uuid) do
      json(conn, %{
        file_uuid: file_uuid,
        status: "processing",
        message: "Upload successful, variants will be generated shortly"
      })
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "UNAUTHORIZED", message: "Authentication required"})

      {:error, :rate_limit_exceeded} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "RATE_LIMITED", message: "Too many uploads, try again shortly"})

      {:error, :no_file} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "NO_FILE", message: "No file provided"})

      {:error, :invalid_file_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "INVALID_FILE_TYPE", message: "File type not allowed"})

      {:error, :file_too_large} ->
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{
          error: "FILE_TOO_LARGE",
          message: "File size exceeds maximum allowed (#{format_bytes(@upload_config.max_size)})"
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "VALIDATION_ERROR",
          message: "Invalid upload",
          details: changeset_errors(changeset)
        })

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "UPLOAD_FAILED", message: "Upload failed: #{inspect(reason)}"})
    end
  end

  defp extract_upload(params) do
    case params["file"] do
      %Plug.Upload{} = upload -> {:ok, upload}
      _ -> {:error, :no_file}
    end
  end

  defp validate_file_type(upload) do
    if upload.content_type in @upload_config.allowed_types do
      :ok
    else
      {:error, :invalid_file_type}
    end
  end

  defp validate_file_size(upload) do
    case File.stat(upload.path) do
      {:ok, stat} ->
        if stat.size <= @upload_config.max_size do
          :ok
        else
          {:error, :file_too_large}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves the account an upload is attributed to, failing closed.

  Requires an authenticated user (the first argument is
  `conn.assigns[:phoenix_kit_current_user]`). The `user_uuid` request parameter
  — attributing the upload to a *different* account — is honored ONLY when the
  authenticated user holds the Owner or Admin system role; for everyone else
  (including a user who merely holds some module permission) it is ignored and
  the upload is attributed to the uploader.

  An unauthenticated request is refused with `{:error, :no_user}`. The previous
  behavior took the owner straight from `params["user_uuid"]` with the check
  never written, so an anonymous client could attribute a 100 MB upload — and
  the variant-processing job it enqueues — to any account (the #687 class, but a
  write).
  """
  @spec resolve_upload_user(term(), map()) :: {:ok, binary()} | {:error, :no_user}
  def resolve_upload_user(current_user, params) do
    case current_user do
      %PhoenixKit.Users.Auth.User{uuid: uuid} = user ->
        override = params["user_uuid"]

        if is_binary(override) and system_role?(user) do
          {:ok, override}
        else
          {:ok, uuid}
        end

      _ ->
        {:error, :no_user}
    end
  end

  # Strictly Owner/Admin — NOT `can_access_admin_area?/1`, which is also true for
  # any holder of a single module permission. Attributing an upload to another
  # account is a cross-user action that belongs to the two system roles only.
  defp system_role?(user), do: Scope.system_role?(Scope.for_user(user))

  defp process_upload(upload, user_uuid) do
    with {:ok, stat} <- File.stat(upload.path),
         {:ok, file_checksum} <- safe_calculate_file_hash(upload.path) do
      file_size = stat.size

      # Calculate user-specific checksum for per-user duplicate detection
      user_file_checksum = Storage.calculate_user_file_checksum(user_uuid, file_checksum)

      # Check if this user already uploaded this file
      case Storage.get_file_by_user_checksum(user_file_checksum) do
        %StorageFile{} = existing_file ->
          # File already exists for this user, delete temp upload and return existing file
          File.rm(upload.path)
          {:ok, existing_file.uuid}

        nil ->
          # New file for this user, proceed with upload
          perform_upload(upload, user_uuid, file_size, file_checksum)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_calculate_file_hash(file_path) do
    case File.read(file_path) do
      {:ok, data} ->
        hash =
          data
          |> then(&:crypto.hash(:md5, &1))
          |> Base.encode16(case: :lower)

        {:ok, hash}

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp perform_upload(upload, user_uuid, _file_size, file_checksum) do
    # `content_type` here is the client-supplied multipart header, so the
    # filename is passed too — see `Storage.determine_file_type/2`.
    file_type = Storage.determine_file_type(upload.content_type, upload.filename)
    ext = Path.extname(upload.filename) |> String.replace_leading(".", "")

    # Store in buckets with hierarchical path structure
    # The real filename and observed content type ride along so the row keeps
    # them — previously this path stored the multipart tempfile's basename as
    # the original name and an extension-guessed mime.
    case Storage.store_file_in_buckets(
           upload.path,
           file_type,
           user_uuid,
           file_checksum,
           ext,
           upload.filename,
           mime_type: upload.content_type
         ) do
      {:ok, file} ->
        # Best-effort: the upload stands even when the job cannot be queued.
        _ = Storage.queue_variant_generation(file, user_uuid, upload.filename)

        {:ok, file.uuid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_bytes(bytes), do: Format.bytes(bytes, decimals: 2)

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), msg) |> to_string()
      end)
    end)
  end
end
