defmodule PhoenixKitWeb.Components.UserDashboardNav do
  @moduledoc """
  User dashboard navigation components for the PhoenixKit user dashboard.
  Provides navigation elements specifically for user dashboard pages.
  """

  use PhoenixKitWeb, :html

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  # Guest dropdown link catalog. Each entry is
  # `{key, path, icon, label_fn, setting_gate_fn}`; `label_fn`/`gate_fn`
  # are zero-arity so gettext + settings are evaluated at render time
  # (per-request locale / live setting), not at compile time.
  @guest_link_catalog [
    {:login, "/users/log-in", "hero-arrow-right-on-rectangle"},
    {:register, "/users/register", "hero-user-plus"},
    {:reset, "/users/reset-password", "hero-key"},
    {:magic_link, "/users/magic-link", "hero-sparkles"}
  ]

  @doc """
  Renders the user widget for dashboard navigation.

  For authenticated visitors this is the avatar dropdown (email,
  Admin/Dashboard/Settings, language switcher, log out). For anonymous
  visitors the same dropdown *shape* is rendered with a generic
  "not signed in" icon and guest-relevant links (log in, sign up, forgot
  password, magic link) plus the same language switcher — so a single
  widget covers both states and always offers a language switcher.

  ## Attributes

    * `:scope` — current scope; `nil`/unauthenticated renders the guest dropdown.
    * `:current_path` — used for active-link highlighting and locale-switch URLs.
    * `:current_locale` — base code of the active locale (highlighted in the list).
    * `:show_language_switcher` — include the in-menu language list (default `true`).
      Set `false` when the host renders a standalone switcher elsewhere to avoid
      a duplicate. Applies to both the signed-in and guest states.
    * `:guest_links` — which guest links may appear, e.g.
      `[:login, :register, :reset, :magic_link]` (default: all). Links are also
      gated by the `allow_registration` / `magic_link_login_enabled` settings, so
      this list can only narrow, never force-enable a disabled feature.
    * `:authenticated_links` — which authenticated-menu entries may appear, e.g.
      `[:admin, :dashboard, :settings, :logout]` (default: all). Same narrowing
      rule as `:guest_links` — `:admin` still requires `Scope.can_access_admin_area?/1` to be
      true, so listing it can't grant an entry a non-admin shouldn't see. Use
      this to hide entries (e.g. `:dashboard`) a host app's own navigation
      already covers.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")
  attr(:admin_edit_url, :string, default: nil)
  attr(:admin_edit_label, :string, default: nil)
  attr(:show_language_switcher, :boolean, default: true)
  attr(:guest_links, :list, default: [:login, :register, :reset, :magic_link])
  attr(:authenticated_links, :list, default: [:admin, :dashboard, :settings, :logout])

  def user_dropdown(assigns) do
    user = Scope.user(assigns.scope)
    multi_session_allowed? = assigns.scope && assigns.scope.multi_session_allowed?
    accounts = (assigns.scope && assigns.scope.multi_session_accounts) || []

    assigns =
      assigns
      |> assign(:user, user)
      |> assign(:multi_session_allowed?, multi_session_allowed?)
      |> assign(:accounts, accounts)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
        <div
          tabindex="0"
          role="button"
          class="cursor-pointer hover:opacity-80 transition-opacity"
        >
          <PhoenixKitWeb.Components.Core.UserInfo.user_avatar
            user={@user}
            size="md"
            class="!rounded-lg"
          />
        </div>

        <ul
          tabindex="0"
          class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3 max-h-[calc(100vh-5rem)] overflow-y-auto flex-nowrap"
        >
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
            </div>
          </li>

          <div class="divider my-0"></div>

          <%= if :admin in @authenticated_links && PhoenixKit.Users.Auth.Scope.can_access_admin_area?(@scope) do %>
            <li>
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin")}
                class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/admin"), do: " bg-primary text-primary-content", else: "")}
              >
                <.icon name="hero-shield-check" class="w-4 h-4" />
                <span>{gettext("Admin Panel")}</span>
              </.link>
            </li>
            <%= if @admin_edit_url do %>
              <li>
                <a
                  href={@admin_edit_url}
                  class="flex items-center gap-3"
                >
                  <.icon name="hero-pencil-square" class="w-4 h-4" />
                  <span>{@admin_edit_label || "Edit"}</span>
                </a>
              </li>
            <% end %>
          <% end %>

          <li :if={:dashboard in @authenticated_links}>
            <.link
              navigate={PhoenixKit.Utils.Routes.path("/dashboard", locale: @current_locale)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/dashboard"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-home" class="w-4 h-4" />
              <span>{gettext("Dashboard")}</span>
            </.link>
          </li>

          <li :if={:settings in @authenticated_links}>
            <.link
              navigate={PhoenixKit.Utils.Routes.user_settings_path(locale: @current_locale)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/profile/settings"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
              <span>{gettext("Settings")}</span>
            </.link>
          </li>

          <.language_menu_section
            :if={@show_language_switcher}
            current_path={@current_path}
            current_locale={@current_locale}
          />

          <%= if @multi_session_allowed? do %>
            <div class="divider my-0"></div>

            <li class="menu-title px-4 py-1">
              <span class="text-xs">{gettext("Accounts")}</span>
            </li>

            <%= for account <- @accounts do %>
              <li class="p-0">
                <%= if account.active? do %>
                  <div class="flex items-center gap-3 px-4 py-2 rounded-lg bg-base-200 min-w-0">
                    <span class="flex-1 min-w-0 truncate" title={account.email}>
                      {account.email}
                    </span>
                    <span class="badge badge-xs badge-ghost shrink-0">{account.role}</span>
                    <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 shrink-0" />
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 px-1 min-w-0">
                    <.form
                      for={%{}}
                      action={Routes.locale_aware_path(assigns, "/users/session/active")}
                      method="put"
                      class="flex-1 min-w-0"
                    >
                      <input type="hidden" name="ref" value={account.ref} />
                      <input type="hidden" name="return_to" value={@current_path} />
                      <button
                        type="submit"
                        class="flex w-full min-w-0 items-center gap-3 px-3 py-2 rounded-lg hover:bg-base-200"
                      >
                        <span class="flex-1 min-w-0 truncate" title={account.email}>
                          {account.email}
                        </span>
                        <span class="badge badge-xs badge-ghost ml-auto shrink-0">
                          {account.role}
                        </span>
                      </button>
                    </.form>
                    <%= unless account.root? do %>
                      <.form
                        for={%{}}
                        action={
                          Routes.locale_aware_path(assigns, "/users/session/accounts/#{account.ref}")
                        }
                        method="delete"
                      >
                        <input type="hidden" name="return_to" value={@current_path} />
                        <button
                          type="submit"
                          class="btn btn-ghost btn-xs btn-square text-error shrink-0"
                          title="Remove"
                        >
                          ✕
                        </button>
                      </.form>
                    <% end %>
                  </div>
                <% end %>
              </li>
            <% end %>

            <li class="p-0">
              <label
                for="pk-add-account-modal-dashboard"
                class="flex items-center gap-3 px-4 py-2 rounded-lg hover:bg-base-200 cursor-pointer"
              >
                <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-4 h-4" />
                <span>{gettext("Add account")}</span>
              </label>
            </li>
          <% end %>

          <div class="divider my-0"></div>

          <li :if={:logout in @authenticated_links}>
            <.link
              navigate={Routes.path("/users/log-out")}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              <span>{gettext("Log Out")}</span>
            </.link>
          </li>
          <li :if={
            :logout in @authenticated_links and @multi_session_allowed? and length(@accounts) > 1
          }>
            <.link
              navigate={Routes.path("/users/log-out") <> "?all=1"}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              <span>{gettext("Log out from all accounts")}</span>
            </.link>
          </li>
        </ul>
      </div>

      <%= if @multi_session_allowed? do %>
        <input type="checkbox" id="pk-add-account-modal-dashboard" class="modal-toggle" />
        <div class="modal" role="dialog">
          <div class="modal-box">
            <h3 class="text-lg font-bold mb-4">{gettext("Add account")}</h3>
            <.form
              for={%{}}
              action={Routes.locale_aware_path(assigns, "/users/session/accounts")}
              method="post"
              class="space-y-4"
            >
              <input type="hidden" name="return_to" value={@current_path} />
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">{gettext("Email or username")}</span></label>
                <input
                  name="user[email_or_username]"
                  type="text"
                  required
                  class="input w-full"
                />
              </div>
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">{gettext("Password")}</span></label>
                <input
                  name="user[password]"
                  type="password"
                  required
                  class="input w-full"
                />
              </div>
              <div class="modal-action">
                <label for="pk-add-account-modal-dashboard" class="btn btn-outline">
                  {gettext("Cancel")}
                </label>
                <button type="submit" class="btn btn-primary">{gettext("Add account")}</button>
              </div>
            </.form>
            <.add_account_oauth_buttons current_path={@current_path} />
          </div>
          <label class="modal-backdrop" for="pk-add-account-modal-dashboard">{gettext("Close")}</label>
        </div>
      <% end %>
    <% else %>
      <.guest_dropdown
        current_path={@current_path}
        current_locale={@current_locale}
        guest_links={@guest_links}
        show_language_switcher={@show_language_switcher}
      />
    <% end %>
    """
  end

  # OAuth buttons for the "Add account" modal.
  # Uses the same provider availability checks as the main login page —
  # a provider button only appears when it is enabled in General Settings.
  # Each link targets /users/auth/:provider with add_account=1 so the OAuth
  # callback knows to append the result to the multi-session stack.
  # Duplicated from AdminNav's private component of the same name rather
  # than shared — keeps this frontend-facing module independent of the
  # admin-only one.
  attr :current_path, :string, default: "/"

  defp add_account_oauth_buttons(assigns) do
    google_enabled = OAuthAvailability.provider_enabled?(:google)
    github_enabled = OAuthAvailability.provider_enabled?(:github)
    facebook_enabled = OAuthAvailability.provider_enabled?(:facebook)

    any_enabled = google_enabled or github_enabled or facebook_enabled

    assigns =
      assigns
      |> assign(:google_enabled, google_enabled)
      |> assign(:github_enabled, github_enabled)
      |> assign(:facebook_enabled, facebook_enabled)
      |> assign(:any_enabled, any_enabled)

    ~H"""
    <%= if @any_enabled do %>
      <div class="mt-4">
        <div class="divider text-base-content/60 text-xs">{gettext("Or add via")}</div>
        <div class="space-y-2">
          <%= if @google_enabled do %>
            <.link
              href={
                Routes.path("/users/auth/google", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_google class="w-5 h-5" />
              <span>{gettext("Add Google account")}</span>
            </.link>
          <% end %>
          <%= if @github_enabled do %>
            <.link
              href={
                Routes.path("/users/auth/github", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_github class="w-5 h-5" />
              <span>{gettext("Add GitHub account")}</span>
            </.link>
          <% end %>
          <%= if @facebook_enabled do %>
            <.link
              href={
                Routes.path("/users/auth/facebook", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_facebook class="w-5 h-5" />
              <span>{gettext("Add Facebook account")}</span>
            </.link>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  # Guest counterpart to the authenticated avatar dropdown: same shape and
  # styling, a generic "not signed in" trigger icon, guest-relevant links,
  # and the shared language switcher.
  attr(:current_path, :string, required: true)
  attr(:current_locale, :string, required: true)
  attr(:guest_links, :list, required: true)
  attr(:show_language_switcher, :boolean, required: true)

  defp guest_dropdown(assigns) do
    assigns = assign(assigns, :links, visible_guest_links(assigns.guest_links))

    ~H"""
    <div class="dropdown dropdown-end">
      <div
        tabindex="0"
        role="button"
        class="cursor-pointer hover:opacity-80 transition-opacity"
        aria-label={gettext("Account menu")}
      >
        <%!--
          Rounded-rectangle placeholder matching the authenticated avatar shape
          (md = w-10 h-10, rounded-lg via its `!rounded-lg`), so the guest and
          signed-in triggers look consistent — a generic person silhouette
          signals "not signed in".
        --%>
        <div class="w-10 h-10 rounded-lg bg-base-300 flex items-center justify-center text-base-content/60">
          <.icon name="hero-user" class="w-6 h-6" />
        </div>
      </div>

      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3 max-h-[calc(100vh-5rem)] overflow-y-auto flex-nowrap"
      >
        <li class="menu-title px-4 py-2">
          <span class="text-sm font-medium text-base-content">{gettext("Not signed in")}</span>
        </li>

        <div class="divider my-0"></div>

        <li :for={link <- @links}>
          <.link navigate={Routes.path(link.path)} class="flex items-center gap-3">
            <.icon name={link.icon} class="w-4 h-4" />
            <span>{link.label}</span>
          </.link>
        </li>

        <.language_menu_section
          :if={@show_language_switcher}
          current_path={@current_path}
          current_locale={@current_locale}
        />
      </ul>
    </div>
    """
  end

  # Shared, independently scrollable language list used by both the
  # authenticated and guest dropdowns. Renders nothing when fewer than two
  # languages are enabled. Anchors are styled directly (no nested daisyUI
  # `<ul class="menu">`) so the parent menu doesn't apply submenu indent or
  # li-child padding that would force horizontal scroll. See admin_nav.ex
  # for the matching pattern.
  attr(:current_path, :string, required: true)
  attr(:current_locale, :string, required: true)

  defp language_menu_section(assigns) do
    # Highlight by BASE code, not full-dialect equality. `@current_locale`
    # may be a base ("en", per the attr doc) or a resolved dialect that
    # differs from the enabled one (e.g. `resolve_dialect("en")` => "en-US"
    # while English is enabled as "en-GB"), so a raw `==` against the
    # enabled dialect never matched on the default locale. Comparing bases
    # makes en/en-GB/en-US all match and works whether the caller passes a
    # base or a dialect — same rule the standalone `Core.LanguageSwitcher` uses.
    current_base = DialectMapper.extract_base(assigns.current_locale)

    user_languages =
      Enum.map(get_user_languages(), fn language ->
        Map.put(language, :active?, DialectMapper.extract_base(language.code) == current_base)
      end)

    assigns = assign(assigns, :user_languages, user_languages)

    ~H"""
    <%= if length(@user_languages) > 1 do %>
      <div class="divider my-0"></div>

      <li class="menu-title px-4 py-1">
        <span class="text-xs">{gettext("Language")}</span>
      </li>

      <li class="p-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
        <div class="!p-0 block w-full max-h-60 overflow-y-auto overflow-x-hidden !bg-transparent hover:!bg-transparent focus:!bg-transparent">
          <a
            :for={language <- @user_languages}
            href={
              Routes.locale_switch_path(@current_path, language.code,
                current_locale: assigns[:current_locale]
              )
            }
            class={[
              "w-full flex items-center gap-3 rounded-lg px-4 py-2 text-sm",
              "focus:outline-none focus-visible:outline-none",
              if(language.active?,
                do:
                  "bg-primary !text-primary-content hover:bg-primary hover:!text-primary-content active:!bg-primary/80",
                else:
                  "!text-base-content hover:bg-base-200 hover:!text-base-content focus:!text-base-content active:!text-base-content active:!bg-base-300"
              )
            ]}
          >
            <span class="text-lg">{get_language_flag(language.code)}</span>
            <span>{language.name}</span>
            <%= if language.active? do %>
              <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
            <% end %>
          </a>
        </div>
      </li>
    <% end %>
    """
  end

  # Resolves which guest links to render: starts from the catalog, keeps
  # only keys the caller allowed, and applies the per-feature settings
  # gates (`allow_registration`, `magic_link_login_enabled`). Log in and
  # forgot-password are always available; the others are gated.
  defp visible_guest_links(allowed) do
    allow_registration? = Settings.get_boolean_setting("allow_registration", true)
    magic_link? = Settings.get_boolean_setting("magic_link_login_enabled", true)

    @guest_link_catalog
    |> Enum.filter(fn {key, _path, _icon} ->
      key in allowed and guest_link_enabled?(key, allow_registration?, magic_link?)
    end)
    |> Enum.map(fn {key, path, icon} ->
      %{key: key, path: path, icon: icon, label: guest_link_label(key)}
    end)
  end

  defp guest_link_enabled?(:register, allow_registration?, _magic?), do: allow_registration?
  defp guest_link_enabled?(:magic_link, _allow?, magic?), do: magic?
  defp guest_link_enabled?(_key, _allow?, _magic?), do: true

  defp guest_link_label(:login), do: gettext("Log in")
  defp guest_link_label(:register), do: gettext("Sign up")
  defp guest_link_label(:reset), do: gettext("Forgot password")
  defp guest_link_label(:magic_link), do: gettext("Magic link")

  # Helper function to get user languages from Languages module
  # Returns enabled languages or falls back to English if module is disabled
  defp get_user_languages do
    # Get enabled languages from the Languages module
    languages =
      if Languages.enabled?() do
        Languages.get_enabled_languages()
      else
        # Fallback to English when module is disabled
        [%{code: "en-US", name: "English (United States)", is_enabled: true}]
      end

    # Map to expected format with enriched data from predefined languages.
    # The final `dedupe_names/1` call drops the country qualifier when
    # only one dialect of a given base language is configured — the
    # same rule the frontend switcher applies, called from its
    # canonical home in `Core.LanguageSwitcher` so the logic lives in
    # one place.
    languages
    |> Enum.map(fn lang ->
      case Languages.get_predefined_language(lang.code) do
        %{name: name, flag: flag, native: native} ->
          %{code: lang.code, name: name, flag: flag, native: native}

        nil ->
          %{code: lang.code, name: String.upcase(lang.code), flag: "🌐", native: ""}
      end
    end)
    |> LanguageSwitcher.dedupe_names()
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end

  # Check if current path matches the given path
  defp active_path?(current_path, path) when is_binary(current_path) and is_binary(path) do
    # Remove PhoenixKit prefix if present
    normalized_path = remove_phoenix_kit_prefix(current_path)
    # Remove locale prefix if present
    clean_path = remove_locale_prefix(normalized_path)

    # Check for exact match or ends with path
    clean_path == path or String.ends_with?(clean_path, path)
  end

  defp active_path?(_, _), do: false

  # Remove PhoenixKit prefix
  defp remove_phoenix_kit_prefix(path) do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    if url_prefix == "/" do
      path
    else
      String.replace_prefix(path, url_prefix, "")
    end
  end

  # Remove locale prefix
  defp remove_locale_prefix(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when locale != "" and rest != "" ->
        if looks_like_locale?(locale), do: "/" <> rest, else: path

      ["", locale] ->
        if looks_like_locale?(locale), do: "/", else: path

      _ ->
        path
    end
  end

  # Check if it looks like a locale code
  defp looks_like_locale?(locale) do
    String.length(locale) <= 8 and String.match?(locale, ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/)
  end
end
