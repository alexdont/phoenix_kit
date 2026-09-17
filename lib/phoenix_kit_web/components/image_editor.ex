defmodule PhoenixKitWeb.Components.ImageEditor do
  @moduledoc """
  Edits a stored image after upload — crop, rotate, flip, straighten,
  redact, brightness and contrast — through
  `PhoenixKit.Modules.Storage.ImageEditing`.

  Everything is a server-rendered form, so the editor works with nothing
  but LiveView: numeric crop and region fields, buttons for the quarter
  turns, sliders for the rest. The `ImageEditor` hook adds drawing the crop
  and the redaction areas on the preview. The preview is CSS over the
  unedited original, so it is close to the result, not exact — tones in
  particular; the saved image is rendered by ImageMagick.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Components.ImageEditor}
        id={"image-editor-" <> @file.uuid}
        file={@file}
        scope={@phoenix_kit_current_scope}
        on_close={JS.push("close_image_editor")}
      />

  ## Assigns

    * `:file` (required) — the `PhoenixKit.Modules.Storage.File`.
    * `:scope` — who is editing. `ImageEditing` decides whether they may
      (the owner, an Owner/Admin, a `"media"` permission holder).
    * `:authorized` (default `false`) — `true` when the host has already
      decided this user may manage the file, and `scope` is only who they
      are. `MediaBrowser` passes it for files inside its folder scope, as
      it does for rotating and deleting them.
    * `:on_close` — a `Phoenix.LiveView.JS` run by the close button.
      Without it there is no close button.

  ## Keeping it current

  Saving queues the rendering; the editor shows the progress until the
  file is processed. The host forwards the storage file events (see
  `PhoenixKit.Modules.Storage.subscribe_to_file_events/0`):

      send_update(PhoenixKitWeb.Components.ImageEditor,
        id: editor_id,
        file_processed: file_uuid
      )
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageEdit
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.FileController

  @styles ~w(blur pixelate fill)
  @aspects [
    {"free", nil},
    {"1:1", {1, 1}},
    {"4:3", {4, 3}},
    {"3:2", {3, 2}},
    {"16:9", {16, 9}},
    {"3:4", {3, 4}},
    {"9:16", {9, 16}}
  ]
  # Seconds a render may take before the editor offers to start it again.
  @stalled_after 120
  # As many areas as `ImageEdit.normalize/1` accepts.
  @max_regions 50
  # Where "Add area" puts a new region, in percent of the frame.
  @new_region %{"x" => 40.0, "y" => 40.0, "w" => 20.0, "h" => 20.0, "style" => "blur"}

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:authorized, false)
     |> assign(:scope, nil)
     |> assign(:on_close, nil)
     |> assign(:tool, "crop")
     |> assign(:aspect, "free")
     |> assign(:error, nil)
     |> assign(:notice, nil)
     |> assign(:confirm, nil)}
  end

  @impl true
  def update(%{file_processed: uuid}, %{assigns: %{file: %{uuid: uuid}}} = socket) do
    {:ok, reload(socket)}
  end

  def update(%{file_processed: _other}, socket), do: {:ok, socket}

  # See `watch_stall/1`.
  def update(%{stall_check: true}, socket), do: {:ok, assign(socket, :now, DateTime.utc_now())}

  def update(assigns, socket) do
    previous = socket.assigns[:file]
    socket = assign(socket, Map.take(assigns, [:id, :scope, :authorized, :on_close]))

    cond do
      is_nil(previous) -> {:ok, load(socket, assigns.file)}
      file_changed?(previous, assigns.file) -> {:ok, load(socket, assigns.file, keep_draft: true)}
      true -> {:ok, socket}
    end
  end

  defp file_changed?(a, b) do
    Map.take(a, [:uuid, :edit_revision, :edit_state, :file_checksum, :original_file_uuid]) !=
      Map.take(b, [:uuid, :edit_revision, :edit_state, :file_checksum, :original_file_uuid])
  end

  # ──────────────────────────────────────────────────────────────
  # State
  # ──────────────────────────────────────────────────────────────

  defp reload(socket) do
    case Storage.get_file(socket.assigns.file.uuid) do
      nil -> assign(socket, :file, nil)
      file -> load(socket, file, keep_draft: true)
    end
  end

  # `keep_draft`: a finished render must not throw away what the user has
  # been changing meanwhile — unless the draft is the edit that just
  # finished, which it then simply stays.
  defp load(socket, file, opts \\ []) do
    draft =
      if Keyword.get(opts, :keep_draft, false) and Map.has_key?(socket.assigns, :draft),
        do: socket.assigns.draft,
        else: file.edits || %{}

    edited? = ImageEditing.edited?(file)

    socket
    |> assign(:file, file)
    |> assign(:now, DateTime.utc_now())
    |> watch_stall()
    |> assign(:draft, draft)
    |> assign(:size, source_size(file))
    |> assign(:annotations, ImageEditing.annotation_count(file))
    |> assign(:preview_url, preview_url(socket, file))
    |> assign(:unedited_url, if(edited?, do: unedited_url(socket, file)))
  end

  # A pending edit offers "start again" once it has taken long; re-render
  # then even if nothing else happens.
  defp watch_stall(
         %{assigns: %{file: %{edit_state: "pending", updated_at: %DateTime{} = at}}} = socket
       ) do
    if connected?(socket) do
      due =
        max(
          DateTime.diff(DateTime.add(at, @stalled_after + 1), DateTime.utc_now(), :millisecond),
          0
        )

      send_update_after(__MODULE__, %{id: socket.assigns.id, stall_check: true}, due)
    end

    socket
  end

  defp watch_stall(socket), do: socket

  # The unedited original's dimensions (what the edit is applied to).
  defp source_size(file) do
    source = if ImageEditing.edited?(file), do: ImageEditing.backup(file), else: file

    case source do
      %{width: w, height: h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 -> {w, h}
      _ -> nil
    end
  end

  defp preview_url(socket, file) do
    if ImageEditing.edited?(file) do
      unedited_url(socket, file, "large")
    else
      instance =
        Storage.get_file_instance_by_name(file.uuid, "large") ||
          Storage.get_file_instance_by_name(file.uuid, "original")

      instance &&
        URLSigner.signed_url(file.uuid, instance.variant_name, version: instance)
    end
  end

  defp unedited_url(socket, file, variant \\ nil) do
    FileController.unedited_url(socket, file.uuid, user_uuid(socket), variant: variant)
  end

  defp user_uuid(socket), do: socket.assigns.scope && Scope.user_uuid(socket.assigns.scope)

  defp auth_opts(%{assigns: %{authorized: true}}), do: [system: true]
  defp auth_opts(socket), do: [scope: socket.assigns.scope]

  defp allowed?(socket), do: ImageEditing.can_edit?(socket.assigns.file, auth_opts(socket))

  # ──────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("change", %{"edit" => params} = all, socket) do
    socket =
      socket
      |> assign(:draft, merge_draft(socket.assigns.draft, params))
      |> assign(:tool, pick(all["tool"], ~w(crop redact), socket.assigns.tool))
      |> assign(:error, nil)

    {:noreply, socket}
  end

  def handle_event("change", _params, socket), do: {:noreply, socket}

  # Turning and mirroring keep the crop and the areas on their pixels
  # (`ImageEdit.turn/2`, `ImageEdit.mirror/2`).
  def handle_event("turn", %{"to" => to}, socket) when to in ~w(left right) do
    draft = ImageEdit.turn(socket.assigns.draft, String.to_existing_atom(to))
    {:noreply, socket |> assign(:draft, draft) |> assign(:aspect, "free")}
  end

  def handle_event("mirror", %{"axis" => axis}, socket) when axis in ~w(horizontal vertical) do
    draft = ImageEdit.mirror(socket.assigns.draft, String.to_existing_atom(axis))
    {:noreply, assign(socket, :draft, draft)}
  end

  def handle_event("aspect", %{"aspect" => aspect}, socket) do
    case {List.keyfind(@aspects, aspect, 0), socket.assigns.size} do
      {{_, {aw, ah}}, {_, _} = size} ->
        crop = ImageEdit.centred_crop(socket.assigns.draft, {aw, ah}, size)

        {:noreply,
         socket
         |> assign(:aspect, aspect)
         |> assign(:draft, Map.put(socket.assigns.draft, "crop", crop))}

      {{_, nil}, _} ->
        {:noreply, assign(socket, :aspect, aspect)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_crop", _params, socket) do
    {:noreply,
     socket
     |> assign(:aspect, "free")
     |> assign(:draft, Map.delete(socket.assigns.draft, "crop"))}
  end

  # From the hook: the preview image is the recorded size turned a quarter
  # (an upload with an EXIF rotation, recorded before dimensions were read
  # oriented). The frame follows what is displayed — and rendered.
  def handle_event("turned_source", _params, socket) do
    case socket.assigns.size do
      {w, h} -> {:noreply, assign(socket, :size, {h, w})}
      nil -> {:noreply, socket}
    end
  end

  # From the hook: a rectangle drawn on the preview, in percent of the frame.
  def handle_event("drawn", %{"tool" => tool} = rect, socket) do
    case drawn_rect(rect) do
      {:ok, rect} -> {:noreply, assign(socket, :draft, add_drawn(socket, tool, rect))}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("add_region", _params, socket) do
    regions = regions(socket.assigns.draft)

    if length(regions) < @max_regions do
      region = Map.put(@new_region, "style", last_style(socket))

      {:noreply,
       assign(socket, :draft, Map.put(socket.assigns.draft, "redact", regions ++ [region]))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_region", %{"index" => index}, socket) do
    case Integer.parse(to_string(index)) do
      {i, ""} ->
        regions = List.delete_at(regions(socket.assigns.draft), i)
        {:noreply, assign(socket, :draft, Map.put(socket.assigns.draft, "redact", regions))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:draft, socket.assigns.file.edits || %{})
     |> assign(:aspect, "free")
     |> assign(:error, nil)}
  end

  def handle_event("save", params, socket) do
    socket = assign(socket, :draft, merge_draft(socket.assigns.draft, params["edit"] || %{}))
    file = socket.assigns.file
    draft = socket.assigns.draft

    case params["intent"] do
      "copy" ->
        case ImageEditing.save_copy(file, draft, auth_opts(socket)) do
          {:ok, _job} ->
            {:noreply,
             assign(
               socket,
               :notice,
               gettext("A copy is being made. It will appear next to the original.")
             )}

          {:error, reason} ->
            {:noreply, assign(socket, :error, error_message(reason))}
        end

      _save ->
        case ImageEditing.edit(file, draft, auth_opts(socket)) do
          {:ok, file} ->
            {:noreply,
             socket
             |> load(file, keep_draft: true)
             |> assign(:notice, nil)
             |> assign(:error, nil)}

          {:error, reason} ->
            {:noreply, socket |> assign(:error, error_message(reason)) |> reload()}
        end
    end
  end

  def handle_event("retry", _params, socket) do
    result = ImageEditing.retry(socket.assigns.file, auth_opts(socket))
    {:noreply, after_action(socket, result)}
  end

  def handle_event("confirm", %{"action" => action}, socket)
      when action in ~w(revert delete_unedited) do
    {:noreply, assign(socket, :confirm, action)}
  end

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("revert", _params, socket) do
    result = ImageEditing.revert(socket.assigns.file, auth_opts(socket))

    socket
    |> assign(:confirm, nil)
    |> after_action(result)
    |> then(fn socket -> {:noreply, assign(socket, :draft, %{})} end)
  end

  def handle_event("delete_unedited", _params, socket) do
    result = ImageEditing.delete_unedited_original(socket.assigns.file, auth_opts(socket))

    socket
    |> assign(:confirm, nil)
    |> after_action(result)
    |> then(&{:noreply, &1})
  end

  defp after_action(socket, {:ok, file}),
    do: socket |> load(file) |> assign(:error, nil)

  defp after_action(socket, {:error, reason}),
    do: socket |> assign(:error, error_message(reason)) |> reload()

  # ──────────────────────────────────────────────────────────────
  # Draft helpers
  # ──────────────────────────────────────────────────────────────

  # The form carries the fields; the quarter turn and the mirrors are kept
  # from the draft (only their buttons change them, together with the
  # rectangles).
  defp merge_draft(draft, params) do
    params =
      params
      |> Map.merge(Map.take(draft, ~w(rotate flip_h flip_v)))
      |> Map.update("crop", nil, &blank_crop/1)

    case ImageEdit.normalize(params) do
      {:ok, nil} -> %{}
      {:ok, edit} -> edit
      {:error, _} -> draft
    end
  end

  # An untouched crop (the whole frame) is no crop.
  defp blank_crop(%{} = crop) do
    if Enum.all?(~w(x y w h), &(to_string(crop[&1] || "") == "")), do: nil, else: crop
  end

  defp blank_crop(other), do: other

  defp regions(draft), do: Map.get(draft, "redact", [])

  defp last_style(socket) do
    case List.last(regions(socket.assigns.draft)) do
      %{"style" => style} -> style
      _ -> "blur"
    end
  end

  defp add_drawn(socket, "redact", rect) do
    regions = regions(socket.assigns.draft) ++ [Map.put(rect, "style", last_style(socket))]
    Map.put(socket.assigns.draft, "redact", Enum.take(regions, @max_regions))
  end

  defp add_drawn(socket, _crop, rect), do: Map.put(socket.assigns.draft, "crop", rect)

  defp drawn_rect(params) do
    case ImageEdit.normalize(%{"redact" => [Map.put(params, "style", "fill")]}) do
      {:ok, %{"redact" => [rect]}} -> {:ok, Map.delete(rect, "style")}
      _ -> :error
    end
  end

  defp frame(socket) do
    case socket.assigns.size do
      nil -> nil
      size -> ImageEdit.frame_size(socket.assigns.draft, size)
    end
  end

  defp pick(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp error_message(:forbidden), do: gettext("You can't edit this image.")
  defp error_message(:not_editable), do: gettext("This file can't be edited.")
  defp error_message(:not_found), do: gettext("This file no longer exists.")

  defp error_message(:not_queued),
    do: gettext("Saved, but the image could not be queued for rendering. Try again.")

  defp error_message(:no_edit),
    do: gettext("Nothing to save: the copy would be the same as the original.")

  defp error_message(:not_edited), do: gettext("This image has no unedited original.")
  defp error_message(:nothing_to_retry), do: gettext("There is nothing to retry.")

  defp error_message(:edit_changed),
    do: gettext("The image changed meanwhile. Check it and try again.")

  defp error_message(:edit_in_progress),
    do: gettext("Wait until the image has finished rendering.")

  defp error_message({:annotated, count}),
    do:
      ngettext(
        "This image has an annotation. Cropping, turning, flipping or straightening it would move the annotation off its place. Save a copy instead.",
        "This image has %{count} annotations. Cropping, turning, flipping or straightening it would move them off their places. Save a copy instead.",
        count
      )

  defp error_message({:invalid_edit, _}), do: gettext("Some of the values are not valid.")

  defp error_message(reason) do
    Logger.warning("ImageEditor: #{inspect(reason)}")
    gettext("Something went wrong. Try again.")
  end

  # ──────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────

  @impl true
  def render(%{file: nil} = assigns) do
    ~H"""
    <div id={@id} class="p-6 text-center text-base-content/70">
      {gettext("This file no longer exists.")}
    </div>
    """
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:allowed, allowed?(%{assigns: assigns}))
      |> assign(:editable, ImageEditing.editable?(assigns.file))
      |> assign(:busy, ImageEditing.edit_in_progress?(assigns.file))
      |> assign(:failed, assigns.file.edit_state == "failed")
      |> assign(:edited, ImageEditing.edited?(assigns.file))
      |> assign(:frame, frame(%{assigns: assigns}))
      |> assign(:geometry_locked, assigns.annotations > 0)
      |> assign(:replace_mode, ImageEditing.mode() == "replace_original")
      |> assign(:dirty, assigns.draft != (assigns.file.edits || %{}))
      |> assign(:styles, @styles)
      |> assign(:aspects, Enum.map(@aspects, &elem(&1, 0)))

    ~H"""
    <div id={@id} class="flex flex-col lg:flex-row gap-4 min-h-0 h-full">
      <%!-- Preview --%>
      <div class="flex-1 min-w-0 min-h-0 flex flex-col gap-2">
        <div
          id={"#{@id}-stage"}
          class="relative flex-1 min-h-[16rem] bg-base-200 rounded-lg grid place-items-center overflow-hidden p-4"
        >
          <%= if @preview_url && @frame do %>
            <% {fw, fh} = @frame %>
            <div
              id={"#{@id}-frame"}
              phx-hook="ImageEditor"
              phx-target={@myself}
              data-tool={@tool}
              data-aspect={aspect_ratio(@aspect)}
              data-frame-width={fw}
              data-frame-height={fh}
              data-source-width={elem(@size, 0)}
              data-source-height={elem(@size, 1)}
              data-locked={to_string(@geometry_locked and @tool == "crop")}
              class={[
                "relative max-w-full max-h-full overflow-hidden touch-none select-none",
                @tool == "crop" && !@geometry_locked && "cursor-crosshair",
                @tool == "redact" && "cursor-cell"
              ]}
              style={"aspect-ratio: #{fw} / #{fh}; width: min(100%, calc(65vh * #{fw} / #{fh}));"}
            >
              <img
                src={@preview_url}
                alt=""
                draggable="false"
                class="absolute left-1/2 top-1/2 max-w-none pointer-events-none"
                style={image_style(@draft, @size, @frame)}
              />
              <%!-- Redaction areas --%>
              <div
                :for={{region, index} <- Enum.with_index(Map.get(@draft, "redact", []))}
                class={["absolute", region_class(region["style"])]}
                style={rect_style(region)}
                data-region={index}
              >
                <span class="absolute -top-5 left-0 badge badge-xs badge-neutral">{index + 1}</span>
              </div>
              <%!-- Crop: the parts that go are shaded --%>
              <%= if crop = @draft["crop"] do %>
                <div class="absolute inset-0 pointer-events-none" style={shade_style(crop)}></div>
                <div
                  class="absolute border-2 border-white shadow-[0_0_0_1px_rgba(0,0,0,0.6)] pointer-events-none"
                  style={rect_style(crop)}
                >
                  <div class="absolute inset-0 grid grid-cols-3 grid-rows-3">
                    <div :for={_ <- 1..9} class="border border-white/30"></div>
                  </div>
                </div>
              <% end %>
              <div
                id={"#{@id}-draft"}
                phx-update="ignore"
                data-draft
                class="absolute hidden border-2 border-dashed border-primary bg-primary/10 pointer-events-none"
              >
              </div>
            </div>
          <% else %>
            <p :if={is_nil(@frame)} class="text-sm text-base-content/60">
              {gettext("The image has no dimensions yet. Try again once it has been processed.")}
            </p>
            <p :if={@frame} class="text-sm text-base-content/60">
              {gettext("No preview is available. The fields still work.")}
            </p>
          <% end %>

          <%= if @busy do %>
            <div class="absolute inset-0 bg-base-100/70 grid place-items-center">
              <div class="text-center space-y-2">
                <%= if @failed do %>
                  <.icon name="hero-exclamation-triangle" class="w-8 h-8 text-error mx-auto" />
                  <p class="font-semibold">{gettext("The edit could not be applied.")}</p>
                  <p class="text-sm text-base-content/70 max-w-xs">
                    {gettext("Until it is, the image shows a placeholder everywhere.")}
                  </p>
                  <button
                    :if={@allowed}
                    type="button"
                    phx-click="retry"
                    phx-target={@myself}
                    class="btn btn-sm btn-primary"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Try again")}
                  </button>
                <% else %>
                  <span class="loading loading-spinner loading-md"></span>
                  <p class="font-semibold">{gettext("Applying the edit…")}</p>
                  <p class="text-sm text-base-content/70 max-w-xs">
                    {gettext("The image shows a placeholder until it is done.")}
                  </p>
                  <%!-- A run that died without a trace (a timeout, a node
                       going away) leaves nothing to finish the edit. --%>
                  <button
                    :if={@allowed and stalled?(@file, @now)}
                    type="button"
                    phx-click="retry"
                    phx-target={@myself}
                    class="btn btn-sm btn-ghost"
                  >
                    <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext(
                      "Taking long? Start again"
                    )}
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
        <p class="text-xs text-base-content/60">
          {gettext("The preview is approximate; colours and blur are exact once saved.")}
        </p>
      </div>

      <%!-- Controls --%>
      <div class="w-full lg:w-80 lg:flex-none min-w-0 flex flex-col gap-3 overflow-y-auto">
        <div class="flex items-center gap-2">
          <h3 class="font-semibold flex-1 truncate">{gettext("Edit image")}</h3>
          <button
            :if={@on_close}
            type="button"
            phx-click={@on_close}
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <div :if={@error} role="alert" class="alert alert-error text-sm py-2">{@error}</div>
        <div :if={@notice} role="status" class="alert alert-info text-sm py-2">{@notice}</div>

        <%= cond do %>
          <% not @editable -> %>
            <p class="text-sm text-base-content/70">
              {gettext("Only still JPEG, PNG, WebP, AVIF, TIFF and BMP images can be edited.")}
            </p>
          <% not @allowed -> %>
            <p class="text-sm text-base-content/70">{gettext("You can't edit this image.")}</p>
          <% true -> %>
            <.form
              for={%{}}
              as={:edit}
              id={"#{@id}-form"}
              phx-change="change"
              phx-submit="save"
              phx-target={@myself}
              class="flex flex-col gap-4"
            >
              <fieldset disabled={@busy and not @failed} class="flex flex-col gap-4">
                <div role="tablist" class="tabs tabs-box tabs-sm">
                  <label
                    :for={
                      {value, label} <- [{"crop", gettext("Crop")}, {"redact", gettext("Hide areas")}]
                    }
                    class={["tab", @tool == value && "tab-active"]}
                  >
                    <input
                      type="radio"
                      name="tool"
                      value={value}
                      checked={@tool == value}
                      class="sr-only"
                    />
                    {label}
                  </label>
                </div>

                <div :if={@geometry_locked} class="alert alert-warning text-xs py-2">
                  {ngettext(
                    "This image has an annotation, so it can't be cropped, turned, flipped or straightened (the annotation would end up in the wrong place). Save a copy for that.",
                    "This image has %{count} annotations, so it can't be cropped, turned, flipped or straightened (they would end up in the wrong place). Save a copy for that.",
                    @annotations
                  )}
                </div>

                <%!-- Geometry --%>
                <section :if={@tool == "crop" and not @geometry_locked} class="flex flex-col gap-3">
                  <div class="flex flex-wrap gap-1">
                    <button
                      type="button"
                      phx-click="turn"
                      phx-value-to="left"
                      phx-target={@myself}
                      class="btn btn-sm btn-square"
                      title={gettext("Turn left")}
                      aria-label={gettext("Turn left")}
                    >
                      <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="turn"
                      phx-value-to="right"
                      phx-target={@myself}
                      class="btn btn-sm btn-square"
                      title={gettext("Turn right")}
                      aria-label={gettext("Turn right")}
                    >
                      <.icon name="hero-arrow-uturn-right" class="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="mirror"
                      phx-value-axis="horizontal"
                      phx-target={@myself}
                      aria-pressed={to_string(@draft["flip_h"] == true)}
                      class={["btn btn-sm", @draft["flip_h"] && "btn-active"]}
                    >
                      <.icon name="hero-arrows-right-left" class="w-4 h-4" /> {gettext("Mirror")}
                    </button>
                    <button
                      type="button"
                      phx-click="mirror"
                      phx-value-axis="vertical"
                      phx-target={@myself}
                      aria-pressed={to_string(@draft["flip_v"] == true)}
                      class={["btn btn-sm", @draft["flip_v"] && "btn-active"]}
                    >
                      <.icon name="hero-arrows-up-down" class="w-4 h-4" /> {gettext("Flip")}
                    </button>
                  </div>

                  <label class="flex flex-col gap-1 text-sm">
                    <span class="flex justify-between">
                      {gettext("Straighten")}
                      <span class="tabular-nums text-base-content/70">{format_degrees(
                        @draft["straighten"]
                      )}</span>
                    </span>
                    <input
                      type="range"
                      name="edit[straighten]"
                      min="-45"
                      max="45"
                      step="0.5"
                      value={@draft["straighten"] || 0}
                      class="range range-xs"
                    />
                  </label>

                  <div class="flex flex-col gap-1 text-sm">
                    <span>{gettext("Crop")}</span>
                    <div class="flex flex-wrap gap-1">
                      <button
                        :for={aspect <- @aspects}
                        type="button"
                        phx-click="aspect"
                        phx-value-aspect={aspect}
                        phx-target={@myself}
                        class={["btn btn-xs", @aspect == aspect && "btn-primary"]}
                      >
                        {if aspect == "free", do: gettext("Free"), else: aspect}
                      </button>
                      <button
                        :if={@draft["crop"]}
                        type="button"
                        phx-click="clear_crop"
                        phx-target={@myself}
                        class="btn btn-xs btn-ghost"
                      >
                        {gettext("No crop")}
                      </button>
                    </div>
                    <div class="grid grid-cols-4 gap-1">
                      <label
                        :for={
                          {key, label} <- [
                            {"x", gettext("Left %")},
                            {"y", gettext("Top %")},
                            {"w", gettext("Width %")},
                            {"h", gettext("Height %")}
                          ]
                        }
                        class="flex flex-col text-xs"
                      >
                        <span class="text-base-content/70">{label}</span>
                        <input
                          type="number"
                          step="any"
                          min="0"
                          max="100"
                          name={"edit[crop][#{key}]"}
                          value={crop_value(@draft["crop"], key)}
                          class="input input-xs w-full"
                        />
                      </label>
                    </div>
                  </div>
                </section>

                <%!-- The geometric fields still travel with the form while
                     another tool is open, so they are not reset. --%>
                <div :if={@tool != "crop" or @geometry_locked} class="hidden">
                  <input type="hidden" name="edit[straighten]" value={@draft["straighten"] || 0} />
                  <input
                    :for={key <- ~w(x y w h)}
                    type="hidden"
                    name={"edit[crop][#{key}]"}
                    value={crop_value(@draft["crop"], key)}
                  />
                </div>

                <%!-- Redaction --%>
                <section :if={@tool == "redact"} class="flex flex-col gap-2">
                  <p class="text-xs text-base-content/70">
                    {gettext(
                      "Drag on the image to cover an area, or add one and set it below. Covered areas are permanently removed from the saved image."
                    )}
                  </p>
                  <div
                    :for={{region, index} <- Enum.with_index(Map.get(@draft, "redact", []))}
                    class="flex flex-col gap-1 rounded-box bg-base-200 p-2"
                  >
                    <div class="flex items-center gap-2">
                      <span class="badge badge-sm badge-neutral">{index + 1}</span>
                      <select name={"edit[redact][#{index}][style]"} class="select select-xs flex-1">
                        <option
                          :for={style <- @styles}
                          value={style}
                          selected={region["style"] == style}
                        >
                          {style_label(style)}
                        </option>
                      </select>
                      <button
                        type="button"
                        phx-click="remove_region"
                        phx-value-index={index}
                        phx-target={@myself}
                        class="btn btn-ghost btn-xs btn-square"
                        aria-label={gettext("Remove area")}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    </div>
                    <div class="grid grid-cols-4 gap-1">
                      <input
                        :for={key <- ~w(x y w h)}
                        type="number"
                        step="any"
                        min="0"
                        max="100"
                        name={"edit[redact][#{index}][#{key}]"}
                        value={region[key]}
                        aria-label={rect_label(key)}
                        class="input input-xs w-full"
                      />
                    </div>
                  </div>
                  <button
                    type="button"
                    phx-click="add_region"
                    phx-target={@myself}
                    class="btn btn-sm btn-outline"
                  >
                    <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add area")}
                  </button>
                </section>

                <div :if={@tool != "redact"} class="hidden">
                  <%= for {region, index} <- Enum.with_index(Map.get(@draft, "redact", [])) do %>
                    <input
                      :for={key <- ~w(x y w h style)}
                      type="hidden"
                      name={"edit[redact][#{index}][#{key}]"}
                      value={region[key]}
                    />
                  <% end %>
                </div>

                <%!-- Light --%>
                <section class="flex flex-col gap-2">
                  <label
                    :for={
                      {key, label} <- [
                        {"brightness", gettext("Brightness")},
                        {"contrast", gettext("Contrast")}
                      ]
                    }
                    class="flex flex-col gap-1 text-sm"
                  >
                    <span class="flex justify-between">
                      {label}
                      <span class="tabular-nums text-base-content/70">{@draft[key] || 0}</span>
                    </span>
                    <input
                      type="range"
                      name={"edit[#{key}]"}
                      min="-100"
                      max="100"
                      step="1"
                      value={@draft[key] || 0}
                      class="range range-xs"
                    />
                  </label>
                </section>

                <div :if={@frame} class="text-xs text-base-content/60">
                  <% {ow, oh} = ImageEdit.output_size(@draft, @size) %>
                  {gettext("Result: %{width} × %{height} px", width: ow, height: oh)}
                </div>

                <div :if={@replace_mode} class="alert alert-warning text-xs py-2">
                  {gettext("Saving replaces the original image. This can't be undone.")}
                </div>

                <div class="flex flex-wrap gap-2">
                  <button
                    type="submit"
                    name="intent"
                    value="save"
                    class="btn btn-primary btn-sm"
                    disabled={not @dirty}
                  >
                    {gettext("Save")}
                  </button>
                  <button
                    type="submit"
                    name="intent"
                    value="copy"
                    class="btn btn-sm"
                    disabled={@draft == %{}}
                  >
                    {gettext("Save as copy")}
                  </button>
                  <button
                    type="button"
                    phx-click="reset"
                    phx-target={@myself}
                    class="btn btn-ghost btn-sm"
                    disabled={not @dirty}
                  >
                    {gettext("Undo changes")}
                  </button>
                </div>
              </fieldset>
            </.form>

            <%!-- The unedited original --%>
            <div :if={@edited} class="card bg-base-200">
              <div class="card-body p-3 gap-2 text-sm">
                <p class="font-semibold">{gettext("Unedited original")}</p>
                <p class="text-xs text-base-content/70">
                  {gettext(
                    "Kept privately so the edit can be changed or undone. Only people who can edit this image can get it."
                  )}
                </p>
                <div class="flex flex-wrap gap-2">
                  <a :if={@unedited_url} href={@unedited_url} class="btn btn-xs" download>
                    <.icon name="hero-arrow-down-tray" class="w-3 h-3" /> {gettext("Download")}
                  </a>
                  <button
                    type="button"
                    phx-click="confirm"
                    phx-value-action="revert"
                    phx-target={@myself}
                    class="btn btn-xs"
                    disabled={
                      (@busy and not @failed) or
                        (@geometry_locked and ImageEdit.geometric?(@file.edits))
                    }
                  >
                    <.icon name="hero-arrow-uturn-left" class="w-3 h-3" /> {gettext("Restore")}
                  </button>
                  <button
                    type="button"
                    phx-click="confirm"
                    phx-value-action="delete_unedited"
                    phx-target={@myself}
                    class="btn btn-xs btn-error btn-outline"
                    disabled={@busy}
                  >
                    <.icon name="hero-trash" class="w-3 h-3" /> {gettext("Delete")}
                  </button>
                </div>

                <div
                  :if={@confirm == "revert"}
                  role="alertdialog"
                  class="alert alert-warning flex-col items-start gap-2 text-xs"
                >
                  <span>{gettext(
                    "Undo the edit and show the unedited original again everywhere this image is used?"
                  )}</span>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      phx-click="revert"
                      phx-target={@myself}
                      class="btn btn-xs btn-warning"
                    >{gettext("Restore original")}</button>
                    <button
                      type="button"
                      phx-click="cancel_confirm"
                      phx-target={@myself}
                      class="btn btn-xs btn-ghost"
                    >{gettext("Cancel")}</button>
                  </div>
                </div>

                <div
                  :if={@confirm == "delete_unedited"}
                  role="alertdialog"
                  class="alert alert-error flex-col items-start gap-2 text-xs"
                >
                  <span>{gettext(
                    "Delete the unedited original for good? The edit becomes permanent and can no longer be changed or undone."
                  )}</span>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      phx-click="delete_unedited"
                      phx-target={@myself}
                      class="btn btn-xs btn-error"
                    >{gettext("Delete for good")}</button>
                    <button
                      type="button"
                      phx-click="cancel_confirm"
                      phx-target={@myself}
                      class="btn btn-xs btn-ghost"
                    >{gettext("Cancel")}</button>
                  </div>
                </div>
              </div>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────
  # Render helpers
  # ──────────────────────────────────────────────────────────────

  # The unedited image inside the frame: turned and mirrored as the edit
  # says, straightened (and scaled so no corner shows), toned.
  defp image_style(draft, {w, h}, {fw, fh}) do
    rotate = draft["rotate"] || 0
    straighten = draft["straighten"] || 0
    scale = ImageEdit.straighten_scale(fw, fh, straighten)
    {sx, sy} = {if(draft["flip_h"], do: -1, else: 1), if(draft["flip_v"], do: -1, else: 1)}

    # Width and height in percent of the frame, before the quarter turn.
    {pw, ph} =
      if rotate in [90, 270],
        do: {w / fw * 100, h / fh * 100},
        else: {100, 100}

    brightness = 1 + (draft["brightness"] || 0) / 100
    contrast = 1 + (draft["contrast"] || 0) / 100

    [
      "width: #{num(pw)}%; height: #{num(ph)}%;",
      "transform: translate(-50%, -50%) rotate(#{num(straighten)}deg) scale(#{num(scale)}) ",
      "scale(#{sx}, #{sy}) rotate(#{rotate}deg);",
      "filter: brightness(#{num(brightness)}) contrast(#{num(contrast)});"
    ]
    |> Enum.join()
  end

  # Saved (or retried) a while ago and still rendering.
  defp stalled?(%{edit_state: "pending", updated_at: %DateTime{} = at}, now),
    do: DateTime.diff(now, at) > @stalled_after

  defp stalled?(_file, _now), do: false

  defp rect_style(%{"x" => x, "y" => y, "w" => w, "h" => h}),
    do: "left: #{num(x)}%; top: #{num(y)}%; width: #{num(w)}%; height: #{num(h)}%;"

  # Everything outside the crop, darkened: one element, four inset shadows
  # would not do; a clip-path polygon with a hole does.
  defp shade_style(%{"x" => x, "y" => y, "w" => w, "h" => h}) do
    {l, t, r, b} = {num(x), num(y), num(x + w), num(y + h)}

    "background: rgb(0 0 0 / 0.55); clip-path: polygon(evenodd, " <>
      "0% 0%, 100% 0%, 100% 100%, 0% 100%, 0% 0%, " <>
      "#{l}% #{t}%, #{r}% #{t}%, #{r}% #{b}%, #{l}% #{b}%, #{l}% #{t}%);"
  end

  defp region_class("fill"), do: "bg-black"

  defp region_class("pixelate"),
    do:
      "backdrop-blur-md bg-base-content/20 [image-rendering:pixelated] outline outline-2 outline-white/70"

  defp region_class(_blur),
    do: "backdrop-blur-xl bg-base-100/10 outline outline-2 outline-white/70"

  defp style_label("blur"), do: gettext("Blur")
  defp style_label("pixelate"), do: gettext("Pixelate")
  defp style_label("fill"), do: gettext("Black box")

  defp rect_label("x"), do: gettext("Left %")
  defp rect_label("y"), do: gettext("Top %")
  defp rect_label("w"), do: gettext("Width %")
  defp rect_label("h"), do: gettext("Height %")

  defp crop_value(nil, key), do: if(key in ~w(w h), do: 100, else: 0)
  defp crop_value(crop, key), do: crop[key]

  defp format_degrees(nil), do: "0°"
  defp format_degrees(value), do: "#{num(value)}°"

  defp aspect_ratio(aspect) do
    case List.keyfind(@aspects, aspect, 0) do
      {_, {w, h}} -> "#{w}/#{h}"
      _ -> ""
    end
  end

  defp num(value) when is_integer(value), do: Integer.to_string(value)

  defp num(value) when is_float(value) do
    rounded = Float.round(value, 3)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, [:compact, decimals: 3])
  end
end
