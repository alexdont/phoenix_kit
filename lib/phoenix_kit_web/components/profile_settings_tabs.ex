defmodule PhoenixKitWeb.Components.ProfileSettingsTabs do
  @moduledoc """
  The tabs of the signed-in user's own settings, `/profile/settings/<tab>`.

  One URL per tab, and a tab is offered only when it has something to show
  for this user:

    * `account` — who you are: avatar and name, custom fields, email, and
      the start page
    * `security` — password and connected sign-in accounts
    * `sessions` — signed-in devices and recent sign-in attempts
    * `notifications` — which notifications you get (when any types exist)
    * `integrations` — your own service connections, for holders of the
      opt-in `integrations` permission. Its own LiveView at
      `/profile/settings/integrations`.
    * `media` — how media behaves for you: the annotation-tools section
      (open-in-editor switch, tool reset), and — while user libraries are
      on and you hold the `"storage"` permission — your storage libraries
      and their members (`PhoenixKitWeb.Live.Components.LibrarySettings`;
      the end-user surface for those is `phoenix_kit_photos`). The tab is
      offered to everyone, because the annotation section applies to
      anyone who can open the media viewer; the library card inside keeps
      its own gate.

  `/profile/settings` opens the first tab. Every section of
  `PhoenixKitWeb.Live.Components.UserSettings.default_sections/0` is on
  exactly one tab (a section on none would be one nobody can reach).
  """
  use PhoenixKitWeb, :html

  alias PhoenixKit.Notifications.Types, as: NotificationTypes
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  # The `UserSettings` sections each tab renders, in page order.
  @sections %{
    "account" => [:identity, :custom_fields, :email, :start_page],
    "security" => [:password, :oauth],
    "sessions" => [:sessions],
    "notifications" => [:notifications],
    "media" => [:etcher]
  }

  @order ~w(account security sessions notifications integrations media)

  @doc "The tab `/profile/settings` opens on."
  @spec default_tab() :: String.t()
  def default_tab, do: "account"

  @doc """
  The `UserSettings` sections a tab rendered by `ProfileSettings` shows, or
  nil for a tab that is not one of them (integrations has a page of its own).
  """
  @spec sections(String.t()) :: [atom()] | nil
  def sections(tab), do: Map.get(@sections, tab)

  @doc "Whether `ProfileSettings` renders the tab itself (every tab but integrations)."
  @spec rendered_here?(String.t()) :: boolean()
  def rendered_here?(tab), do: Map.has_key?(@sections, tab)

  @doc "Every section some tab shows."
  @spec all_sections() :: [atom()]
  def all_sections, do: @sections |> Map.values() |> List.flatten()

  @doc "The ids of the tabs `scope` is offered, in order."
  @spec tab_ids(Scope.t() | nil) :: [String.t()]
  def tab_ids(scope), do: Enum.filter(@order, &visible?(&1, scope))

  defp visible?("notifications", _scope), do: NotificationTypes.list() != []

  defp visible?("integrations", scope),
    do: not is_nil(scope) and Scope.has_module_access?(scope, "integrations")

  # "media" deliberately has no gate: the annotation section on it applies
  # to anyone who can open the media viewer. The libraries card inside the
  # tab keeps its own `Libraries.may_use_libraries?/1` check.
  defp visible?(_tab, _scope), do: true

  @doc "The path of a tab."
  @spec path(String.t()) :: String.t()
  def path(tab), do: Routes.path("/profile/settings/#{tab}")

  @doc """
  The tab strip. `active` is the tab being shown; `scope` decides which tabs
  are offered. Tabs rendered by the same LiveView patch; the integrations
  tab, a LiveView of its own, navigates.
  """
  attr :active, :string, required: true
  attr :scope, :any, required: true

  def profile_tabs(assigns) do
    assigns =
      assign(assigns, :tabs, Enum.map(tab_ids(assigns.scope), &tab(&1, assigns.active)))

    ~H"""
    <.nav_tabs active_tab={@active} tabs={@tabs} variant={:border} class="mb-6" />
    """
  end

  # From inside `ProfileSettings`, the tabs it renders itself patch and the
  # integrations tab navigates; from the integrations page every tab
  # navigates back into `ProfileSettings`.
  defp tab(id, active) do
    link =
      if id != "integrations" and rendered_here?(active),
        do: [patch: path(id)],
        else: [navigate: path(id)]

    Map.merge(%{id: id, label: tab_label(id), icon: tab_icon(id)}, Map.new(link))
  end

  defp tab_label("account"), do: gettext("Account")
  defp tab_label("security"), do: gettext("Security")
  defp tab_label("sessions"), do: gettext("Sessions")
  defp tab_label("notifications"), do: gettext("Notifications")
  defp tab_label("integrations"), do: gettext("Integrations")
  defp tab_label("media"), do: gettext("Media")

  defp tab_icon("account"), do: "hero-user-circle"
  defp tab_icon("security"), do: "hero-lock-closed"
  defp tab_icon("sessions"), do: "hero-computer-desktop"
  defp tab_icon("notifications"), do: "hero-bell"
  defp tab_icon("integrations"), do: "hero-link"
  defp tab_icon("media"), do: "hero-rectangle-stack"
end
