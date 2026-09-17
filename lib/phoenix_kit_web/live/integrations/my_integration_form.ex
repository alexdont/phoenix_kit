defmodule PhoenixKitWeb.Live.Integrations.MyIntegrationForm do
  @moduledoc """
  Add / edit a PERSONAL integration connection for the current user.

  `:new` shows a provider picker (only `for_scope(:personal)` providers), then a
  name + setup-fields form. `:edit` loads the connection owner-scoped and shows
  its setup fields with Test / Delete.

  Every context call is scoped to `owner: {:user, uuid}` where the uuid comes
  ONLY from the request scope — a crafted `:edit` uuid for another user's row
  fails closed (redirects), never exposing their credentials. No OAuth flow:
  personal providers are self-owned-secret types validated in place.

  Renders with the shared `Components.Core.IntegrationsUI` so it stays visually
  consistent with the website-wide page (`Live.Settings.IntegrationForm`).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.IntegrationsUI,
    only: [provider_picker: 1, provider_status_card: 1, setup_field: 1, setup_instructions: 1]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Integrations.Telegram
  alias PhoenixKit.Integrations.Telegram.ChatLink
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.has_module_access?(scope, "integrations") do
      user_uuid = Scope.user_uuid(scope)

      {:ok,
       socket
       |> assign(:page_title, gettext("Integration"))
       |> assign(:project_title, Settings.get_project_title())
       |> assign(:user_uuid, user_uuid)
       |> assign(:providers, Providers.personal_offered())
       |> assign(:selected_provider, nil)
       |> assign(:provider, nil)
       |> assign(:uuid, nil)
       |> assign(:name, nil)
       |> assign(:data, %{})
       # `new_name` / `form_values` hold what the operator typed on the /new
       # flow so a pre-save dry-run Test can re-render the form without
       # eating input.
       |> assign(:new_name, "")
       |> assign(:form_values, %{})
       |> assign(:validating, false)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You don't have access to Integrations."))
       |> redirect(to: Routes.path("/profile/settings"))}
    end
  end

  @impl true
  def handle_params(params, url, socket) do
    {:noreply,
     socket
     |> assign(:url_path, URI.parse(url).path)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("Add Integration"))
    |> assign(:selected_provider, nil)
    |> assign(:provider, nil)
    |> assign(:uuid, nil)
    |> assign(:name, nil)
    |> assign(:data, %{})
    |> assign(:new_name, "")
    |> assign(:form_values, %{})
  end

  defp apply_action(socket, :edit, %{"uuid" => uuid}) do
    # Owner-scoped load — a personal uuid belonging to another user (or a
    # system row) fails closed and redirects, never rendering credentials.
    case Integrations.get_integration_by_uuid(uuid, owner(socket)) do
      {:ok, %{provider: provider_key, name: name, data: data}} ->
        socket
        |> assign(:page_title, gettext("Integration"))
        |> assign(:uuid, uuid)
        |> assign(:name, name)
        |> assign(:data, data)
        |> assign(:selected_provider, provider_key)
        |> assign(:provider, Providers.get(provider_key))

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Integration not found"))
        |> push_navigate(to: Routes.path("/profile/settings/integrations"))
    end
  end

  @impl true
  def handle_event("select_provider", %{"provider" => key}, socket) do
    {:noreply,
     socket
     |> assign(:selected_provider, key)
     |> assign(:provider, Providers.get(key))
     |> assign(:data, %{})
     |> assign(:new_name, "")
     |> assign(:form_values, %{})}
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     assign(socket, selected_provider: nil, provider: nil, new_name: "", form_values: %{})}
  end

  # Pre-save dry-run: probe the provider with the values currently typed, no
  # row created. Preserves the entered name + fields so a failed test doesn't
  # blank the form. `formnovalidate` on the button lets it run without a name.
  def handle_event("save_new", %{"_intent" => "test"} = params, socket) do
    provider_key = socket.assigns.selected_provider
    attrs = setup_attrs(params, socket.assigns.provider)

    socket =
      socket
      |> assign(:new_name, String.trim(params["name"] || ""))
      |> assign(:form_values, attrs)

    {flash_kind, flash_msg} =
      case Integrations.validate_credentials(provider_key, attrs) do
        :ok -> {:info, gettext("Connection works")}
        {:ok, note} -> {:info, note}
        # Neither a pass nor a failure — this provider has no way to check a
        # connection at all, so nothing ran. :warning, not :info/:error —
        # matches the system form's tone (both are wrong in different ways).
        :unverified -> {:warning, gettext("Not tested — this provider has no connection check")}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, put_flash(socket, flash_kind, flash_msg)}
  end

  # Create: birth the row owned by this user, then persist the setup fields.
  def handle_event("save_new", params, socket) do
    provider_key = socket.assigns.selected_provider
    name = String.trim(params["name"] || "")

    with {:ok, %{uuid: uuid}} <-
           Integrations.add_connection(provider_key, name, socket.assigns.user_uuid,
             owner: owner(socket)
           ),
         {:ok, _} <-
           Integrations.save_setup(uuid, setup_attrs(params, socket.assigns.provider), nil,
             owner: owner(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Integration added"))
       |> push_navigate(to: Routes.path("/profile/settings/integrations/#{uuid}"))}
    else
      {:error, :empty_name} ->
        {:noreply, put_flash(socket, :error, gettext("Please enter a name"))}

      {:error, :scope_not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("This provider can't be added here"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add integration"))}
    end
  end

  # Edit: rename first if the name changed, then persist setup fields.
  def handle_event("save", params, socket) do
    name = String.trim(params["name"] || "")

    with :ok <- maybe_rename(socket, name),
         {:ok, data} <-
           Integrations.save_setup(
             socket.assigns.uuid,
             setup_attrs(params, socket.assigns.provider),
             socket.assigns.user_uuid,
             owner: owner(socket)
           ) do
      {:noreply,
       socket
       |> assign(:data, data)
       |> assign(:name, if(name == "", do: socket.assigns.name, else: name))
       |> put_flash(:info, gettext("Saved"))}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save"))}
    end
  end

  def handle_event("validate_connection", _params, socket) do
    send(self(), :do_validate)
    {:noreply, assign(socket, :validating, true)}
  end

  # Telegram: who the bot messages. "single" locks to your one chat; "multi"
  # broadcasts to everyone who has started the bot.
  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ["single", "multi"] do
    case Integrations.save_setup(socket.assigns.uuid, %{"mode" => mode}, socket.assigns.user_uuid,
           owner: owner(socket)
         ) do
      {:ok, _} -> {:noreply, reload(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_mode", _params, socket), do: {:noreply, socket}

  # Clear every captured chat — the escape hatch if the wrong chat got linked
  # (single mode has no nonce, so a stranger who messaged the bot right before
  # Test could be captured). Re-link by messaging the bot again + pressing Test.
  def handle_event("unlink_chats", _params, socket) do
    save_chat_ids(socket, [], gettext("Unlinked. Message the bot and press Test to re-link."))
  end

  # Link a chat by its id. Capture can only reach chats whose update is still
  # in Telegram's ~24h queue; an id the operator already knows (a group's, a
  # channel's) should not depend on that window.
  def handle_event("link_chat", %{"chat_id" => value}, socket) do
    existing = socket.assigns.data["chat_ids"] || []

    case ChatLink.normalize_chat_id(value) do
      {:ok, id} ->
        if id in existing do
          {:noreply, put_flash(socket, :info, gettext("That chat is already linked"))}
        else
          save_chat_ids(socket, existing ++ [id], gettext("Chat linked"))
        end

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Not a chat id — expected a number like -1001234567890, or @channelname")
         )}
    end
  end

  # Remove ONE chat. The all-or-nothing `unlink_chats` above cannot express
  # "drop the group, keep my own chat" once more than one is linked.
  def handle_event("unlink_chat", %{"chat_id" => id}, socket) do
    remaining = Enum.reject(socket.assigns.data["chat_ids"] || [], &(&1 == id))

    save_chat_ids(socket, remaining, gettext("Chat unlinked"))
  end

  def handle_event("delete_connection", _params, socket) do
    Integrations.remove_connection(socket.assigns.uuid, socket.assigns.user_uuid,
      owner: owner(socket)
    )

    {:noreply,
     socket
     |> put_flash(:info, gettext("Integration removed"))
     |> push_navigate(to: Routes.path("/profile/settings/integrations"))}
  end

  @impl true
  def handle_info(:do_validate, socket) do
    result =
      Integrations.validate_connection(socket.assigns.uuid, socket.assigns.user_uuid,
        owner: owner(socket)
      )

    Integrations.record_validation(socket.assigns.uuid, result, owner: owner(socket))

    # For Telegram, Test doubles as chat capture: read the chats that have
    # messaged the bot and store them (single = lock the first, multi = all).
    capture = maybe_capture_telegram_chats(socket)

    flash =
      case result do
        :ok -> capture_flash(capture, socket) || {:info, gettext("Connection works")}
        {:ok, note} -> capture_flash(capture, socket) || {:info, note}
        :unverified -> {:warning, gettext("Not tested — this provider has no connection check")}
        {:error, reason} -> {:error, reason}
      end

    {:noreply,
     socket
     |> assign(:validating, false)
     |> reload()
     |> then(fn s -> put_flash(s, elem(flash, 0), elem(flash, 1)) end)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Telegram chat capture (no-op for other providers). Reads the bot's pending
  # updates and merges the linkable chats per mode — see `ChatLink` for the
  # rules. `save_setup` merges `chat_ids` into the connection data; `reload/1`
  # (called after) refreshes it.
  #
  # Returns what actually happened so the caller's flash can say it: the old
  # version swallowed every outcome into `:ok`, which is why "nothing was
  # captured" and "your chat is linked" both read as "Connection works".
  defp maybe_capture_telegram_chats(
         %{assigns: %{provider: %{key: "telegram"}, uuid: uuid}} = socket
       ) do
    owner = owner(socket)
    mode = socket.assigns.data["mode"] || "single"
    existing = socket.assigns.data["chat_ids"] || []

    case Telegram.get_updates(uuid, offset: nil, owner: owner) do
      {:ok, updates} ->
        %{ids: ids, added: added, meta: meta} =
          ChatLink.capture(
            mode,
            existing,
            socket.assigns.data["chat_meta"] || %{},
            ChatLink.capturable_chats(updates)
          )

        if added != [] do
          Integrations.save_setup(
            uuid,
            %{"chat_ids" => ids, "chat_meta" => meta},
            socket.assigns.user_uuid,
            owner: owner
          )
        end

        {:captured, added}

      _ ->
        :unreachable
    end
  end

  defp maybe_capture_telegram_chats(_socket), do: :not_telegram

  # A working token with nothing linked is the state that used to be reported
  # as plain success — and it is precisely the state in which no notification
  # will ever arrive. Say so.
  defp capture_flash({:captured, [_ | _] = added}, _socket) do
    {:info, gettext("Linked %{count} chat(s)", count: length(added))}
  end

  defp capture_flash({:captured, []}, socket) do
    if socket.assigns.data["chat_ids"] in [nil, []] do
      {:warning,
       gettext(
         "The bot works, but no chat is linked yet — message the bot (or run /start@%{bot} in a group), then press Test again.",
         bot: bot_username(socket.assigns.data)
       )}
    end
  end

  # The token checked out but the update peek didn't: whatever is linked stays
  # linked, and nothing new could have been. Saying "connection works" here
  # would hide the one thing that just failed.
  defp capture_flash(:unreachable, _socket) do
    {:warning, gettext("The bot answers, but its chats could not be read just now — try again.")}
  end

  defp capture_flash(_capture, _socket), do: nil

  # What a linked chat IS, in words. Falls back to the id's own shape when no
  # metadata was captured (a hand-typed id, or one linked before this existed):
  # Telegram signs group ids negative, and an @handle is a channel.
  defp chat_kind_label(id, meta) do
    case (meta || %{})["type"] do
      "private" ->
        gettext("Direct message")

      type when type in ["group", "supergroup"] ->
        gettext("Group")

      "channel" ->
        gettext("Channel")

      _ ->
        cond do
          String.starts_with?(id, "@") -> gettext("Channel")
          ChatLink.group_id?(id) -> gettext("Group")
          true -> gettext("Direct message")
        end
    end
  end

  # BotFather's handle, as recorded by the last successful validation
  # ("Connected as @somebot") — the group command is useless without it, so an
  # unvalidated connection still gets a placeholder to show the shape.
  defp bot_username(data) do
    case Regex.run(~r/@([A-Za-z0-9_]+)/, to_string(data["validation_status"])) do
      [_, name] -> name
      _ -> "yourbot"
    end
  end

  # `chat_meta` (what each linked chat IS, so the card can name it) is kept
  # alongside `chat_ids` rather than inside it: the notifications channel reads
  # that list and must keep seeing plain ids. It follows the list on every
  # write — an unlinked chat's title has no business lingering.
  defp save_chat_ids(socket, ids, message) do
    meta = ChatLink.prune_meta(socket.assigns.data["chat_meta"] || %{}, ids)

    case Integrations.save_setup(
           socket.assigns.uuid,
           %{"chat_ids" => ids, "chat_meta" => meta},
           socket.assigns.user_uuid,
           owner: owner(socket)
         ) do
      {:ok, _} -> {:noreply, socket |> reload() |> put_flash(:info, message)}
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not save the linked chats"))}
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp owner(socket), do: {:user, socket.assigns.user_uuid}

  # Rename only when the posted name is non-empty and actually differs.
  defp maybe_rename(_socket, name)
       when name == "" or name == nil,
       do: :ok

  defp maybe_rename(%{assigns: %{name: name}}, name), do: :ok

  defp maybe_rename(socket, name) do
    case Integrations.rename_connection(socket.assigns.uuid, name, socket.assigns.user_uuid,
           owner: owner(socket)
         ) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp reload(%{assigns: %{uuid: uuid}} = socket) when is_binary(uuid) do
    case Integrations.get_integration_by_uuid(uuid, owner(socket)) do
      {:ok, %{name: name, data: data}} -> socket |> assign(:name, name) |> assign(:data, data)
      _ -> socket
    end
  end

  defp reload(socket), do: socket

  # Only the provider's declared setup-field keys are persisted — form params
  # can't sneak arbitrary keys into the JSONB.
  #
  # Blanks are dropped for `:password` fields ONLY, so an untouched (and never
  # re-rendered) secret can't be blanked by submitting the form. Every other
  # field persists its blank: the website form has always done exactly this, and
  # dropping blanks everywhere meant a cleared optional field — an SMTP CA
  # bundle, a timeout — silently kept its old value with the form showing empty.
  defp setup_attrs(params, %{setup_fields: fields}) when is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      value = String.trim(to_string(params[field.key] || ""))

      if Map.get(field, :type) == :password and value == "" do
        acc
      else
        Map.put(acc, field.key, value)
      end
    end)
  end

  defp setup_attrs(_params, _provider), do: %{}

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      page_section={gettext("Profile Settings")}
      page_section_path={Routes.path("/profile/settings")}
      page_crumbs={[
        %{label: gettext("My Integrations"), path: Routes.path("/profile/settings/integrations")}
      ]}
      page_subtitle={if @provider == nil, do: gettext("Choose a service to connect")}
      current_path={@url_path}
      project_title={@project_title}
      current_locale={assigns[:current_locale]}
    >
      <div class="px-4 py-6">
        <%!-- Step 1: Provider picker (new mode, no provider selected yet) --%>
        <div :if={@live_action == :new && @selected_provider == nil} class="max-w-4xl mx-auto">
          <.provider_picker providers={@providers} />
        </div>

        <%!-- Step 2: Setup form (provider selected in new mode, or edit mode) --%>
        <div :if={@provider != nil} class="space-y-6 max-w-4xl mx-auto">
          <button
            :if={@live_action == :new}
            phx-click="back_to_providers"
            class="btn btn-ghost btn-sm -mt-2"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            {gettext("Choose a different service")}
          </button>

          <.provider_status_card provider={@provider} data={@data} name={@name} />

          <form phx-submit={if @live_action == :new, do: "save_new", else: "save"} autocomplete="off">
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body py-4 space-y-4">
                <%!-- Connection name — editable in both modes; the edit save
                     renames when it changes. --%>
                <div class="fieldset">
                  <label class="label" for="field-name">
                    <span class="fieldset-legend">{gettext("Connection Name")}</span>
                  </label>
                  <input
                    type="text"
                    id="field-name"
                    name="name"
                    value={@name || @new_name}
                    class="input w-full"
                    placeholder={gettext("e.g. My personal key")}
                    required
                  />
                </div>

                <.setup_field
                  :for={field <- @provider.setup_fields}
                  field={field}
                  typed_value={to_string(Map.get(@form_values, field.key) || "")}
                  saved_value={to_string(@data[field.key] || "")}
                />

                <div class="flex flex-wrap gap-2 items-center pt-2">
                  <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving…")}>
                    {if @live_action == :new,
                      do: gettext("Create Connection"),
                      else: gettext("Save Changes")}
                  </button>

                  <%!-- Pre-save dry-run on /new: submits with `_intent=test`,
                       `formnovalidate` so a name isn't required just to probe
                       the credentials. On /edit, Test verifies the saved row. --%>
                  <button
                    :if={@live_action == :new}
                    type="submit"
                    name="_intent"
                    value="test"
                    formnovalidate
                    class="btn btn-outline"
                    phx-disable-with={gettext("Testing…")}
                  >
                    <.icon name="hero-signal" class="w-4 h-4" />
                    {gettext("Test Connection")}
                  </button>

                  <button
                    :if={@live_action == :edit}
                    type="button"
                    phx-click="validate_connection"
                    class={"btn btn-outline #{if @validating, do: "loading"}"}
                    disabled={@validating}
                  >
                    <.icon :if={!@validating} name="hero-signal" class="w-4 h-4" />
                    {if @validating, do: gettext("Testing..."), else: gettext("Test Connection")}
                  </button>
                </div>
              </div>
            </div>
          </form>

          <%!-- Telegram notifications: mode + captured chats. Test (above)
               doubles as chat capture. --%>
          <div
            :if={@live_action == :edit and @provider.key == "telegram"}
            class="card bg-base-100 shadow-sm"
          >
            <div class="card-body py-4 space-y-3">
              <h3 class="card-title text-base">{gettext("Notifications")}</h3>
              <p class="text-sm text-base-content/60">
                {gettext(
                  "Message your bot, then press Test above — we'll capture your chat so it can notify you."
                )}
              </p>

              <form id="telegram-mode-form" phx-change="set_mode">
                <.select
                  name="mode"
                  label={gettext("Who does this bot message?")}
                  value={@data["mode"] || "single"}
                  options={[
                    {gettext("Only me"), "single"},
                    {gettext("Everyone who starts the bot"), "multi"}
                  ]}
                />
              </form>

              <p :if={(@data["mode"] || "single") == "multi"} class="text-xs text-warning">
                {gettext(
                  "Anyone who starts this bot will be linked on the next Test and will receive every notification sent here. Use it only for a bot you hand out deliberately."
                )}
              </p>

              <% chats = @data["chat_ids"] || [] %>
              <% meta = @data["chat_meta"] || %{} %>

              <p :if={chats == []} class="text-xs text-warning">
                {gettext("No chats linked yet — nothing will be delivered.")}
              </p>

              <ul :if={chats != []} class="divide-y divide-base-200">
                <li :for={id <- chats} class="flex items-center justify-between gap-3 py-1.5">
                  <span class="text-xs">
                    <span class="badge badge-ghost badge-sm mr-2">
                      {chat_kind_label(id, meta[id])}
                    </span>
                    <span :if={meta[id]["title"]} class="mr-2">{meta[id]["title"]}</span>
                    <span class="font-mono text-base-content/60">{id}</span>
                  </span>
                  <button
                    type="button"
                    phx-click="unlink_chat"
                    phx-value-chat_id={id}
                    data-confirm={gettext("Stop sending notifications to this chat?")}
                    class="btn btn-ghost btn-xs text-error gap-1"
                  >
                    <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                    {gettext("Unlink")}
                  </button>
                </li>
              </ul>

              <%!-- Two ways in, because capture alone cannot reach every chat:
                   it only sees updates still in Telegram's ~24h queue. --%>
              <div class="rounded-box bg-base-200/50 p-3 space-y-2 text-xs">
                <p class="font-medium">{gettext("How to link a chat")}</p>
                <p>
                  {gettext("Your own chat:")}
                  <span class="font-mono">
                    /start
                  </span>
                  {gettext("the bot in Telegram, then press Test Connection above.")}
                </p>
                <p>
                  {gettext("A group:")} {gettext("add the bot to the group, then send")}
                  <span class="font-mono">/start@{bot_username(@data)}</span>
                  {gettext(
                    "there and press Test Connection. A group needs that command — bots cannot read ordinary group messages."
                  )}
                </p>
              </div>

              <form id="telegram-link-chat-form" phx-submit="link_chat" class="flex items-end gap-2">
                <div class="flex-1">
                  <.input
                    type="text"
                    id="telegram-chat-id-input"
                    name="chat_id"
                    value=""
                    label={gettext("Or link a chat by ID")}
                    placeholder="-1001234567890"
                  />
                </div>
                <button type="submit" class="btn btn-outline btn-sm">
                  {gettext("Link")}
                </button>
              </form>
            </div>
          </div>

          <.setup_instructions provider={@provider} open={@live_action == :new} />

          <%!-- Danger Zone (edit mode only). Personal connections have no
               OAuth to disconnect — just permanent removal. --%>
          <details :if={@live_action == :edit} class="card bg-base-100 border-2 border-error/30">
            <summary class="card-body py-3 cursor-pointer flex-row items-center gap-2 select-none">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error" />
              <h3 class="font-semibold text-error text-base">
                {gettext("Danger Zone")}
              </h3>
              <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
            </summary>

            <div class="card-body pt-0 space-y-4">
              <div class="flex items-center justify-between gap-4">
                <div>
                  <p class="font-medium text-sm">{gettext("Delete this connection")}</p>
                  <p class="text-xs text-base-content/60">
                    {gettext(
                      "Removes the integration permanently. Any module pinned to this connection will stop working until repointed."
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="delete_connection"
                  class="btn btn-outline btn-error btn-sm shrink-0"
                  data-confirm={gettext("Permanently delete this connection? This cannot be undone.")}
                  phx-disable-with={gettext("Deleting…")}
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                  {gettext("Delete")}
                </button>
              </div>
            </div>
          </details>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
