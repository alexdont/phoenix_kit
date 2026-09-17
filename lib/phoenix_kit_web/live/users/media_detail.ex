defmodule PhoenixKitWeb.Live.Users.MediaDetail do
  @moduledoc """
  Single media file detail view for PhoenixKit admin panel.

  Provides a shareable view for a specific uploaded media file by file_uuid.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.FileLocation
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.ImageEditor
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Get file_uuid from params. A non-UUID segment (truncated link, typo)
    # must land on the "file not found" state, not raise Ecto.Query.CastError.
    file_uuid =
      case Ecto.UUID.cast(params["file_uuid"] || "") do
        {:ok, uuid} -> uuid
        :error -> nil
      end

    # Batch load all settings needed for this page
    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    # An edit renders in the background; its progress and result arrive as
    # storage file events.
    if connected?(socket) and file_uuid, do: Storage.subscribe_to_file_events()

    socket =
      socket
      |> assign(:page_title, "Media Detail")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:file_uuid, file_uuid)
      |> assign(:show_delete_modal, false)
      |> assign(:image_editor_open, params["edit"] == "image")
      |> load_file_data(file_uuid)
      |> assign(
        :viewer_annotations,
        if(file_uuid, do: MediaCanvasViewer.load_annotations_for(file_uuid), else: [])
      )
      |> maybe_select_annotation(file_uuid, params["annotation"])

    {:ok, socket}
  end

  # Deep-link from a comment's "file" resource (e.g. the comments moderation
  # admin) can carry `?annotation=<uuid>` to focus the Etcher shape the comment
  # is anchored to. Push the select-shape event; the JS bridge retries until the
  # canvas layer is ready (the event is a no-op on the static mount).
  defp maybe_select_annotation(socket, file_uuid, annotation_uuid)
       when is_binary(file_uuid) and is_binary(annotation_uuid) and annotation_uuid != "" do
    Phoenix.LiveView.push_event(socket, "etcher:select-shape", %{
      fresco_id: "media-zoom-" <> file_uuid,
      uuid: annotation_uuid
    })
  end

  defp maybe_select_annotation(socket, _file_uuid, _annotation_uuid), do: socket

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  def handle_event("delete_file", _params, socket) do
    file = socket.assigns.file

    case Storage.trash_file(file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File moved to trash")
         |> push_navigate(to: Routes.path("/admin/media"))}

      {:error, reason} ->
        Logger.error("Failed to trash file #{file.uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, "Failed to delete file")}
    end
  end

  def handle_event("restore_file", _params, socket) do
    case Storage.restore_file(socket.assigns.file) do
      {:ok, _file} ->
        {:noreply,
         socket
         |> load_file_data(socket.assigns.file_uuid)
         |> put_flash(:info, "File restored")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore file")}
    end
  end

  def handle_event("permanently_delete_file", _params, socket) do
    case Storage.delete_file_completely(socket.assigns.file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File permanently deleted")
         |> push_navigate(to: Routes.path("/admin/media"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete file")}
    end
  end

  def handle_event("open_image_editor", _params, socket) do
    {:noreply, assign(socket, :image_editor_open, true)}
  end

  def handle_event("close_image_editor", _params, socket) do
    {:noreply, assign(socket, :image_editor_open, false)}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, !socket.assigns.edit_mode)}
  end

  def handle_event("save_metadata", params, socket) do
    %{"title" => title, "description" => description, "tags" => tags_input} = params

    # Parse tags from comma-separated string
    tags =
      tags_input
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 0))

    # Update metadata
    updated_metadata =
      (socket.assigns.file.metadata || %{})
      |> Map.put("title", title)
      |> Map.put("description", description)
      |> Map.put("tags", tags)

    case Storage.update_file(socket.assigns.file, %{metadata: updated_metadata}) do
      {:ok, updated_file} ->
        # Update file_data with new metadata
        updated_file_data =
          socket.assigns.file_data
          |> Map.put(:title, title)
          |> Map.put(:description, description)
          |> Map.put(:tags, tags)
          |> Map.put(:metadata, updated_metadata)

        socket =
          socket
          |> assign(:file, updated_file)
          |> assign(:file_data, updated_file_data)
          |> assign(:edit_mode, false)
          |> put_flash(:info, "Metadata saved successfully!")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to save metadata")
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, false)}
  end

  def handle_event("regenerate_variants", _params, socket) do
    file = socket.assigns.file

    case VariantGenerator.generate_variants(file) do
      {:ok, instances} ->
        # instances is a list of successfully created FileInstance structs
        count = length(instances)

        socket =
          socket
          |> load_file_data(file.uuid)
          |> put_flash(:info, "Regenerated #{count} variants")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to regenerate: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # The embedded CommentsComponent's Leaf editor reports its content via a
  # {:leaf_changed, ...} process message to this host LV; without forwarding
  # it to the component, "Post Comment" silently no-ops. phoenix_kit_comments
  # is optional from core, so resolve it at runtime (safe no-op if absent).
  # NOTE: defining handle_info means unmatched messages no longer hit
  # LiveView's default — hence the catch-all below.
  def handle_info({:leaf_changed, _} = msg, socket) do
    PhoenixKitWeb.CommentsForwarding.forward_leaf_changed(msg, socket)
  end

  # Comment activity on this file (sidebar create/delete — the comments
  # component reports to the host process): poke the canvas component so
  # the tooltip counts and on-shape badges refresh in place.
  def handle_info({:comments_updated, %{resource_type: "file", resource_uuid: uuid}}, socket) do
    case socket.assigns[:file_data] do
      %{file_uuid: ^uuid} ->
        Phoenix.LiveView.send_update(PhoenixKitWeb.Components.MediaCanvasViewer,
          id: socket.assigns.canvas_id,
          action: :refresh_annotations
        )

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # This file was processed (an image edit rendered, variants regenerated):
  # show the new state, and tell the open editor.
  def handle_info({:phoenix_kit_file_processed, uuid}, %{assigns: %{file_uuid: uuid}} = socket) do
    if socket.assigns.image_editor_open do
      send_update(ImageEditor, id: image_editor_id(uuid), file_processed: uuid)
    end

    {:noreply, load_file_data(socket, uuid)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp image_editor_id(uuid), do: "media-detail-image-editor-" <> uuid

  defp load_file_data(socket, nil) do
    socket
    |> assign(:file, nil)
    |> assign(:file_data, nil)
  end

  defp load_file_data(socket, file_uuid) do
    repo = PhoenixKit.Config.get_repo()

    case repo.get(File, file_uuid) do
      nil ->
        socket
        |> assign(:file, nil)
        |> assign(:file_data, nil)

      file ->
        instances = load_file_instances(file_uuid, repo)
        urls = generate_urls_from_instances(instances, file_uuid, file.mime_type)
        variant_dimensions = build_variant_dimensions(instances)
        locations = load_original_locations(instances, repo)
        {title, description, tags} = extract_metadata_fields(file.metadata)
        user_name = get_user_name(file.user_uuid, repo)

        variant_dimensions = put_original_fallbacks(variant_dimensions, file)

        file_data =
          build_file_data(
            file,
            urls,
            variant_dimensions,
            locations,
            {title, description, tags},
            user_name
          )

        socket
        |> assign(:file, file)
        |> assign(:file_data, file_data)
        |> assign(:edit_mode, socket.assigns[:edit_mode] || false)
        |> assign(:image_editable, ImageEditing.editable?(file))
        # The canvas keeps its own state; a new original (an edit) must
        # remount it with the new image and dimensions.
        |> assign(:canvas_id, "media-detail-canvas-#{file_uuid}-#{canvas_version(instances)}")
    end
  end

  defp canvas_version(instances) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> "none"
      original -> URLSigner.version(original) || "none"
    end
  end

  defp load_file_instances(file_uuid, repo) do
    FileInstance
    |> where([fi], fi.file_uuid == ^file_uuid)
    |> repo.all()
  end

  defp load_original_locations(instances, repo) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> []
      original_instance -> load_file_locations(original_instance.uuid, repo)
    end
  end

  defp extract_metadata_fields(metadata) do
    metadata = metadata || %{}
    title = metadata["title"] || ""
    description = metadata["description"] || ""
    tags = metadata["tags"] || []
    {title, description, tags}
  end

  defp get_user_name(nil, _repo), do: "Unknown"

  defp get_user_name(user_uuid, repo) do
    alias_module = PhoenixKit.Config.get_users_module()

    case repo.get(alias_module, user_uuid) do
      nil -> "Unknown"
      user -> user.email
    end
  end

  defp build_file_data(
         file,
         urls,
         variant_dimensions,
         locations,
         {title, description, tags},
         user_name
       ) do
    %{
      file_uuid: file.uuid,
      filename: file.original_file_name || file.file_name || "Unknown",
      original_filename: file.original_file_name,
      file_type: file.file_type,
      mime_type: file.mime_type,
      size: file.size || 0,
      status: file.status,
      # Source intrinsic dimensions — drive the Fresco canvas aspect so
      # the embedded MediaCanvasViewer renders the image at its real
      # ratio (instead of `build_viewer_canvas/2`'s 1000×1000 fallback,
      # which fits a square canvas in a wide container with dotted
      # background on the sides).
      width: file.width,
      height: file.height,
      urls: urls,
      variant_dimensions: variant_dimensions,
      title: title,
      description: description,
      tags: tags,
      metadata: file.metadata || %{},
      inserted_at: file.inserted_at,
      updated_at: file.updated_at,
      locations: locations,
      user_name: user_name
    }
  end

  defp build_variant_dimensions(instances) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      dims =
        if instance.width && instance.height, do: {instance.width, instance.height}, else: nil

      Map.put(acc, instance.variant_name, %{dimensions: dims, size: instance.size})
    end)
  end

  # Fill in original variant info from the main file record when the instance lacks it
  defp put_original_fallbacks(variant_dimensions, file) do
    original = Map.get(variant_dimensions, "original", %{dimensions: nil, size: nil})

    dims = original.dimensions || if(file.width && file.height, do: {file.width, file.height})
    size = original.size || file.size

    Map.put(variant_dimensions, "original", %{original | dimensions: dims, size: size})
  end

  # Generate URLs from pre-loaded instances (no database query needed)
  defp generate_urls_from_instances(instances, file_uuid, mime_type) do
    instances
    |> Enum.reduce(%{}, fn instance, acc ->
      url = URLSigner.signed_url(file_uuid, instance.variant_name, version: instance)
      Map.put(acc, instance.variant_name, url)
    end)
    |> URLSigner.put_dzi_url(file_uuid, mime_type,
      version: Enum.find(instances, &(&1.variant_name == "original"))
    )
  end

  # Load file locations with bucket information
  defp load_file_locations(file_instance_uuid, repo) do
    FileLocation
    |> where([fl], fl.file_instance_uuid == ^file_instance_uuid and fl.status == "active")
    |> preload(:bucket)
    |> repo.all()
    |> Enum.map(fn location ->
      %{
        bucket_name: location.bucket.name,
        bucket_provider: location.bucket.provider,
        path: location.path
      }
    end)
  end

  defp format_file_size(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)
end
