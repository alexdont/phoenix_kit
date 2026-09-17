defmodule PhoenixKitWeb.Components.MediaViewer do
  @moduledoc """
  Standalone media lightbox ("slide box") LiveComponent.

  Renders a `<dialog>` modal showing one file from an ordered set, with
  prev/next navigation (chevrons + ←/→ keys) and Escape/backdrop close.
  Per-file content (the pan/zoom canvas with annotations + comments
  thread for images, video/PDF/icon fallback otherwise) is delegated to
  the shared `PhoenixKitWeb.Components.MediaCanvasViewer` child
  LiveComponent — the same one MediaBrowser uses, so admins get the
  full annotation experience here too.

  Reusable on its own or embedded by `MediaGallery`.

  ## Attrs
  - `id` — required
  - `files` — ordered list of file UUIDs (the navigable set)
  - `current` — initial UUID to show (must be in `files`). Treated as
    a seed: once mounted, internal navigation state takes precedence
    over subsequent `current` attr changes. This is intentional when
    the component is mount-gated (`:if={...}`) so it remounts fresh
    on each open. A standalone consumer that keeps the component
    mounted and wants to jump to a different image programmatically
    must unmount and remount it.
  - `current_user` — required for the composer / comments thread to
    render. nil-tolerant (lightbox falls back to view-only).
  - `notify` — optional `{module, id}`; see Close below

  ## Close
  On close, if `notify: {module, id}` is set:
  `send_update(module, id: id, media_viewer_closed: true)`.
  Otherwise: `send(self(), {__MODULE__, id, :closed})`.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:files, assigns[:files] || [])
      |> assign_new(:current_uuid, fn -> assigns[:current] end)
      |> assign(:notify, assigns[:notify])
      |> assign(:current_user, assigns[:current_user])

    {:ok, assign(socket, :current_file, curate_file(socket.assigns.current_uuid))}
  end

  @impl true
  def handle_event("close_viewer", _params, socket) do
    close(socket)
    {:noreply, socket}
  end

  def handle_event("step_viewer", %{"dir" => "prev"}, socket),
    do: {:noreply, step_viewer(socket, :prev)}

  def handle_event("step_viewer", %{"dir" => "next"}, socket),
    do: {:noreply, step_viewer(socket, :next)}

  def handle_event("viewer_keydown", %{"key" => "Escape"}, socket) do
    close(socket)
    {:noreply, socket}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, step_viewer(socket, :prev)}

  def handle_event("viewer_keydown", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, step_viewer(socket, :next)}

  def handle_event("viewer_keydown", _params, socket), do: {:noreply, socket}

  # ── private ──────────────────────────────────────────────────────────

  defp close(socket) do
    case socket.assigns.notify do
      {module, id} -> send_update(module, id: id, media_viewer_closed: true)
      _ -> send(self(), {__MODULE__, socket.assigns.id, :closed})
    end
  end

  defp step_viewer(socket, direction) do
    current = socket.assigns.current_uuid
    list = socket.assigns.files

    with idx when is_integer(idx) <- Enum.find_index(list, &(&1 == current)),
         next_idx <- if(direction == :prev, do: idx - 1, else: idx + 1),
         true <- next_idx >= 0 and next_idx < length(list),
         uuid when is_binary(uuid) <- Enum.at(list, next_idx) do
      socket
      |> assign(:current_uuid, uuid)
      |> assign(:current_file, curate_file(uuid))
    else
      _ -> socket
    end
  end

  # Build the curated file map MediaCanvasViewer expects. Slim version
  # of MediaBrowser's `enrich_files/1` — same shape minus the
  # folder_path (lightbox doesn't show folder breadcrumbs). One File
  # row + one FileInstance query per current file open; the prev/next
  # navigation re-resolves on each step.
  defp curate_file(nil), do: nil

  defp curate_file(file_uuid) when is_binary(file_uuid) do
    case safe(fn -> Storage.get_file(file_uuid) end, nil) do
      nil ->
        nil

      file ->
        instances = safe(fn -> Storage.list_file_instances(file_uuid) end, [])
        original = Enum.find(instances, &(&1.variant_name == "original"))

        urls =
          file_uuid
          |> signed_urls(instances)
          |> URLSigner.put_dzi_url(file_uuid, file.mime_type, version: original)

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          inserted_at: file.inserted_at,
          width: file.width,
          height: file.height,
          urls: urls
        }
    end
  end

  defp signed_urls(file_uuid, instances) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      case safe(
             fn -> URLSigner.signed_url(file_uuid, instance.variant_name, version: instance) end,
             nil
           ) do
        nil -> acc
        url -> Map.put(acc, instance.variant_name, url)
      end
    end)
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    e in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.Query.CastError,
      ArgumentError,
      FunctionClauseError,
      KeyError
    ] ->
      Logger.warning("MediaViewer: data resolve failed — #{Exception.message(e)}")
      fallback
  end
end
