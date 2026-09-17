defmodule PhoenixKit.Modules.Storage.ImageEditing do
  @moduledoc """
  Editing uploaded images after the fact — crop, rotate, flip, straighten,
  redact, brightness and contrast (`PhoenixKit.Modules.Storage.ImageEdit`).

  ## The model

  An edited image **keeps its uuid**: every module that stored the uuid keeps
  showing it, now edited. Its `"original"` instance becomes the edited bytes,
  so every reader of the original — variants, tiles, downloads, public URLs —
  gets the edit without knowing about it. The unedited original is not
  destroyed: its instance rows move to a hidden, system-managed child file
  (`backup/1`) that is never listed and never served by the public file
  routes. The owner reaches it through the editor (download, restore,
  delete) and `GET /api/files/:uuid/unedited`.

  The edit is data (`file.edits`) and is always applied to the unedited
  original, so it can be changed or reverted at any time — until the owner
  deletes the unedited original, which bakes the edit in. With the media
  setting `storage_image_edit_mode` set to `"replace_original"`, every save
  bakes immediately.

  ## While an edit renders

  Saving bumps `edit_revision` and sets `edit_state` to `"pending"`;
  `PhoenixKit.Modules.Storage.ApplyImageEditJob` renders and swaps.
  Until it finishes — and if it fails — every variant of the file is served
  as a neutral placeholder: a half-applied redaction must never show the
  bytes it hides.

  ## Who may edit

  Every function takes `opts` with `:scope` (a `PhoenixKit.Users.Auth.Scope`):
  the file's owner, an Owner/Admin, or a holder of the `"media"` permission
  (the admin media library's) may edit. Trusted internal callers pass `system: true` instead.
  Anything else is `{:error, :forbidden}`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ApplyImageEditJob
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.ImageEdit
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  @backup_name "unedited-original"
  @mode_setting "storage_image_edit_mode"
  @modes ~w(keep_original replace_original)
  # Formats ImageMagick can write back in the same format. GIF is refused:
  # it is usually animated, and a single-frame edit would drop the animation.
  @editable_mimes ~w(image/jpeg image/png image/webp image/avif image/tiff image/bmp)

  @doc "The `file_name` of an edited image's hidden backup."
  def backup_name, do: @backup_name

  @doc """
  What saving an edit does: `"keep_original"` (default) keeps the unedited
  original as a hidden backup; `"replace_original"` bakes the edit in.
  """
  @spec mode() :: String.t()
  def mode do
    case Settings.get_setting_cached(@mode_setting, "keep_original") do
      mode when mode in @modes -> mode
      _ -> "keep_original"
    end
  end

  @doc "The media setting key for `mode/0`."
  def mode_setting, do: @mode_setting

  @doc "The values `mode/0` accepts."
  def modes, do: @modes

  @doc """
  Whether `file` can be edited at all: an active, user-owned still image in a
  format ImageMagick can write back.
  """
  @spec editable?(StorageFile.t() | nil) :: boolean()
  def editable?(%StorageFile{} = file) do
    file.file_type == "image" and editable_mime?(file.mime_type) and
      file.system_managed != true and file.status == "active"
  end

  def editable?(_), do: false

  @doc "Whether images of `mime_type` can be edited (ImageMagick writes them back)."
  @spec editable_mime?(term()) :: boolean()
  def editable_mime?(mime_type), do: mime_type in @editable_mimes

  @doc "Whether `file` has an unedited backup (its edit can be changed or reverted)."
  def edited?(%StorageFile{original_file_uuid: uuid}), do: not is_nil(uuid)
  def edited?(_), do: false

  @doc "Whether an edit of `file` is rendering (or failed); it is served as a placeholder."
  def edit_in_progress?(%StorageFile{edit_state: state}), do: state in ["pending", "failed"]
  def edit_in_progress?(_), do: false

  @doc "An edited file's hidden unedited backup, or nil."
  @spec backup(StorageFile.t()) :: StorageFile.t() | nil
  def backup(%StorageFile{original_file_uuid: nil}), do: nil

  def backup(%StorageFile{uuid: uuid, original_file_uuid: backup_uuid}) do
    from(f in StorageFile,
      where:
        f.uuid == ^backup_uuid and f.parent_file_uuid == ^uuid and f.system_managed == true and
          f.file_name == @backup_name
    )
    |> repo().one()
  end

  @doc """
  Whether `file` is some edited image's hidden backup. Such a file is never
  served by the public file routes.
  """
  def backup?(%StorageFile{system_managed: true, file_name: @backup_name}), do: true
  def backup?(_), do: false

  @doc """
  The instance an edit is applied to: the backup's original when the file
  has been edited, else the file's own original.
  """
  @spec source_instance(StorageFile.t()) :: FileInstance.t() | nil
  def source_instance(%StorageFile{} = file) do
    case backup(file) do
      %StorageFile{} = backup -> Storage.get_file_instance_by_name(backup.uuid, "original")
      nil -> Storage.get_file_instance_by_name(file.uuid, "original")
    end
  end

  @doc """
  Saves an edit of `file` and queues its rendering. `params` is anything
  `ImageEdit.normalize/1` accepts; an edit equal to the current one changes
  nothing.

  Returns `{:ok, file}` (now pending), or `{:error, reason}`:

    * `:forbidden`, `:not_editable`, `:not_found` (deleted meanwhile)
    * `:not_queued` — saved, but the rendering job could not be queued; the
      file stays a placeholder until `retry/2` succeeds
    * `{:invalid_edit, reason}` from `ImageEdit.normalize/1`
    * `{:annotated, count}` — the file has annotations, and the edit changes
      where pixels are (crop, turn, mirror, straighten differ from the
      current edit's): they would no longer line up. Redaction and
      brightness/contrast are allowed; "save as copy" always is.
  """
  @spec edit(StorageFile.t(), map(), keyword()) :: {:ok, StorageFile.t()} | {:error, term()}
  def edit(%StorageFile{} = file, params, opts \\ []) do
    with :ok <- authorize(file, opts),
         :ok <- check_editable(file),
         {:ok, edit} <- normalize(params),
         :ok <- check_annotations(file, edit) do
      if edit == file.edits and not edit_in_progress?(file) do
        {:ok, file}
      else
        start(file, edit)
      end
    end
  end

  @doc """
  Reverts `file` to its unedited original and queues the swap back. Nothing
  to revert is `{:error, :not_edited}`; an annotated file whose edit moved
  pixels is `{:error, {:annotated, count}}`, as for `edit/3`.
  """
  @spec revert(StorageFile.t(), keyword()) :: {:ok, StorageFile.t()} | {:error, term()}
  def revert(%StorageFile{} = file, opts \\ []) do
    with :ok <- authorize(file, opts),
         :ok <- if(edited?(file) or file.edits != nil, do: :ok, else: {:error, :not_edited}),
         :ok <- check_annotations(file, nil) do
      start(file, nil)
    end
  end

  @doc """
  Queues the rendering again for an edit that failed (or seems stuck).
  """
  @spec retry(StorageFile.t(), keyword()) :: {:ok, StorageFile.t()} | {:error, term()}
  def retry(%StorageFile{} = file, opts \\ []) do
    # The caller's struct can be stale (another tab saved since): the retry
    # re-renders the edit the locked row holds, never the one it was shown.
    with :ok <- authorize(file, opts) do
      start(file, :current)
    end
  end

  @doc """
  Deletes the unedited original of an edited `file`, baking the current edit
  in. It cannot be undone. The file keeps serving its edited bytes.
  """
  @spec delete_unedited_original(StorageFile.t(), keyword()) ::
          {:ok, StorageFile.t()} | {:error, term()}
  def delete_unedited_original(%StorageFile{} = file, opts \\ []) do
    with :ok <- authorize(file, opts) do
      bake(file.uuid, file.edit_revision)
    end
  end

  @doc false
  # Deletes the backup and clears the edit, if the file is still at
  # `revision` with no edit rendering. Used by `delete_unedited_original/2`
  # and by the job in replace-original mode.
  def bake(file_uuid, revision) do
    result =
      repo().transaction(fn ->
        file = lock_file(file_uuid) || repo().rollback(:not_found)

        cond do
          file.edit_revision != revision -> repo().rollback(:edit_changed)
          edit_in_progress?(file) -> repo().rollback(:edit_in_progress)
          is_nil(backup(file)) -> repo().rollback(:not_edited)
          true -> :ok
        end

        backup = backup(file)
        Storage.lock_storage_paths([file.file_path, backup.file_path])
        keys = instance_keys([backup.uuid])

        {:ok, _} = repo().delete(backup)

        {:ok, file} =
          file
          |> Ecto.Changeset.change(edits: nil, original_file_uuid: nil)
          |> repo().update()

        {file, Storage.unreferenced_keys(keys)}
      end)

    case result do
      {:ok, {file, keys}} ->
        _ = Storage.delete_stored_objects(keys)
        Storage.broadcast_file_processed(file.uuid)
        {:ok, file}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Renders `params` as a new file (a copy in the same folder, owned by the
  file's owner, with `edited_from_uuid` pointing back). The copy is created
  by a job; `{:ok, job}` means it was queued. Annotations do not matter —
  the copy has none. An edit that changes nothing is `{:error, :no_edit}`.
  """
  @spec save_copy(StorageFile.t(), map(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def save_copy(%StorageFile{} = file, params, opts \\ []) do
    with :ok <- authorize(file, opts),
         :ok <- check_editable(file),
         {:ok, edit} when not is_nil(edit) <- normalize(params) do
      %{
        "file_uuid" => file.uuid,
        "mode" => "copy",
        "edits" => edit,
        "nonce" => Ecto.UUID.generate()
      }
      |> ApplyImageEditJob.new()
      |> Oban.insert()
    else
      {:ok, nil} -> {:error, :no_edit}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:not_queued, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:not_queued, reason}}
  end

  @doc """
  Whether `scope` may edit `file` (see the moduledoc). Also accepts the
  `opts` keyword the other functions take.
  """
  @spec can_edit?(StorageFile.t(), Scope.t() | keyword() | nil) :: boolean()
  def can_edit?(file, opts) when is_list(opts), do: authorize(file, opts) == :ok
  def can_edit?(file, scope), do: authorize(file, scope: scope) == :ok

  ## Internals

  defp start(file, edit) do
    result =
      repo().transaction(fn ->
        current = lock_file(file.uuid) || repo().rollback(:not_found)

        edit =
          cond do
            edit != :current -> edit
            edit_in_progress?(current) -> current.edits
            true -> repo().rollback(:nothing_to_retry)
          end

        {:ok, updated} =
          current
          |> Ecto.Changeset.change(
            edits: edit,
            edit_revision: current.edit_revision + 1,
            edit_state: "pending"
          )
          |> repo().update()

        updated
      end)

    with {:ok, updated} <- result do
      Storage.broadcast_file_processed(updated.uuid)

      case enqueue(updated) do
        :ok -> {:ok, updated}
        :error -> {:error, :not_queued}
      end
    end
  end

  defp enqueue(file) do
    %{"file_uuid" => file.uuid, "mode" => "apply"}
    |> ApplyImageEditJob.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("ImageEditing: could not queue #{file.uuid}: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("ImageEditing: could not queue #{file.uuid}: #{Exception.message(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("ImageEditing: could not queue #{file.uuid}: #{inspect(reason)}")
      :error
  end

  defp normalize(params) do
    case ImageEdit.normalize(params) do
      {:ok, edit} -> {:ok, edit}
      {:error, reason} -> {:error, {:invalid_edit, reason}}
    end
  end

  defp check_editable(file) do
    if editable?(file), do: :ok, else: {:error, :not_editable}
  end

  # Annotations were drawn on the image as it is now, so only a change of
  # geometry moves pixels away from them.
  defp check_annotations(file, edit) do
    if ImageEdit.geometry(edit) != ImageEdit.geometry(file.edits) do
      case annotation_count(file) do
        0 -> :ok
        count -> {:error, {:annotated, count}}
      end
    else
      :ok
    end
  end

  @doc false
  def annotation_count(%StorageFile{uuid: uuid}) do
    if Code.ensure_loaded?(Annotations) and function_exported?(Annotations, :list_for_file, 1),
      do: uuid |> Annotations.list_for_file() |> length(),
      else: 0
  rescue
    _ -> 0
  end

  defp authorize(file, opts) do
    cond do
      Keyword.get(opts, :system) == true -> :ok
      allowed?(file, Keyword.get(opts, :scope)) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp allowed?(%StorageFile{} = file, %Scope{} = scope) do
    uuid = Scope.user_uuid(scope)

    (not is_nil(uuid) and uuid == file.user_uuid) or Scope.system_role?(scope) or
      Scope.has_module_access?(scope, "media")
  end

  defp allowed?(_file, _scope), do: false

  @doc false
  # The file row, locked for the rest of the transaction; nil once deleted.
  def lock_file(file_uuid) do
    from(f in StorageFile, where: f.uuid == ^file_uuid, lock: "FOR UPDATE")
    |> repo().one()
  end

  @doc false
  def instance_keys(file_uuids) do
    from(fi in FileInstance, where: fi.file_uuid in ^file_uuids, select: fi.file_name)
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
