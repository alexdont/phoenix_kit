defmodule PhoenixKitWeb.Components.Core.IntegrationsUI do
  @moduledoc """
  Shared UI for the integration setup screens — the provider picker, the
  provider/status header card, a single setup field, and the collapsible
  setup instructions, plus the small display helpers they need
  (status badge, relative timestamps, inline markdown).

  Extracted so the website-wide integrations pages
  (`Live.Settings.Integrations` / `IntegrationForm`) and the personal
  pages (`Live.Integrations.MyIntegrations` / `MyIntegrationForm`) render
  the *same* markup instead of drifting apart. The personal screens use it
  today; the website screens carry their own equivalents pending a
  convergence pass.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  # ── Display helpers ──────────────────────────────────────────────────

  @doc "Maps a connection status string to `{daisyUI badge class, label}`."
  @spec integration_status_badge(String.t() | nil) :: {String.t(), String.t()}
  def integration_status_badge("connected"), do: {"badge-success", gettext("Connected")}
  def integration_status_badge("configured"), do: {"badge-warning", gettext("Not tested")}
  def integration_status_badge("disconnected"), do: {"badge-ghost", gettext("Not connected")}
  def integration_status_badge("error"), do: {"badge-error", gettext("Error")}
  def integration_status_badge(_), do: {"badge-ghost", gettext("Not configured")}

  @doc """
  Humanizes a UTC ISO8601 timestamp into a relative phrase like
  "2 hours ago" / "3 days ago" / "Apr 28 2026". `nil`/`""` → `nil`; falls
  back to the raw string on parse failure.
  """
  @spec format_relative(String.t() | nil) :: String.t() | nil
  def format_relative(nil), do: nil
  def format_relative(""), do: nil

  def format_relative(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

        cond do
          diff_seconds < 0 -> Calendar.strftime(dt, "%b %-d %Y")
          diff_seconds < 60 -> gettext("just now")
          diff_seconds < 3600 -> gettext_minutes(div(diff_seconds, 60))
          diff_seconds < 86_400 -> gettext_hours(div(diff_seconds, 3600))
          diff_seconds < 7 * 86_400 -> gettext_days(div(diff_seconds, 86_400))
          true -> Calendar.strftime(dt, "%b %-d %Y")
        end

      _ ->
        iso_string
    end
  end

  defp gettext_minutes(1), do: gettext("1 minute ago")
  defp gettext_minutes(n), do: gettext("%{n} minutes ago", n: n)

  defp gettext_hours(1), do: gettext("1 hour ago")
  defp gettext_hours(n), do: gettext("%{n} hours ago", n: n)

  defp gettext_days(1), do: gettext("1 day ago")
  defp gettext_days(n), do: gettext("%{n} days ago", n: n)

  # The link example is in backticks on purpose. Unfenced, ExDoc reads
  # `[links](url)` as a real markdown link and publishes `<a href="url">`, which
  # 404s from the hexdocs page — the same class of dead link #700 set out to
  # remove, and the two "references file \"url\"" warnings it left behind.
  # Backticked, it renders as the syntax this function accepts, which is what the
  # sentence is describing anyway.
  @doc "Simple inline markdown: `**bold**`, `[links](url)`, `` `code` `` and `{variables}`."
  @spec render_markdown_inline(String.t(), map() | keyword()) :: String.t()
  def render_markdown_inline(text, vars) do
    text
    |> replace_vars(vars)
    |> String.replace(~r/`(.+?)`/, "<code class=\"bg-base-300 px-1 rounded text-xs\">\\1</code>")
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\[(.+?)\]\((.+?)\)/, "<a href=\"\\2\" target=\"_blank\">\\1</a>")
  end

  defp replace_vars(text, vars) do
    Enum.reduce(vars, text, fn {key, value}, acc ->
      # `to_string/1` guards against a non-binary value reaching
      # `safe_to_string/1`, which would crash.
      escaped =
        (value || "")
        |> to_string()
        |> Phoenix.HTML.html_escape()
        |> Phoenix.HTML.safe_to_string()

      String.replace(acc, "{#{key}}", escaped)
    end)
  end

  # ── Components ───────────────────────────────────────────────────────

  @doc """
  Provider picker — a card grid, one card per provider. Clicking a card
  pushes `event` (default `"select_provider"`) with `phx-value-provider`.
  """
  attr :providers, :list, required: true
  attr :event, :string, default: "select_provider"

  def provider_picker(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
      <button
        :for={provider <- @providers}
        phx-click={@event}
        phx-value-provider={provider.key}
        class="card bg-base-100 shadow-sm border border-base-300 hover:border-primary transition-colors cursor-pointer"
      >
        <div class="card-body p-4 flex-row items-center gap-3">
          <span class="w-10 h-10 flex items-center justify-center bg-base-200 rounded-lg">
            <.icon name={provider.icon} class="w-5 h-5" />
          </span>
          <div class="text-left">
            <div class="font-semibold">{provider.name}</div>
            <div class="text-xs text-base-content/60">{provider.description}</div>
          </div>
        </div>
      </button>
    </div>
    """
  end

  @doc """
  Provider info / status header card. No badge is shown until the
  connection has actually been saved (`name` set) — a fresh `/new` flow has
  nothing to report yet.
  """
  attr :provider, :map, required: true
  attr :data, :map, required: true
  attr :name, :string, default: nil

  def provider_status_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body py-4">
        <div class="flex items-center gap-3">
          <span class="w-10 h-10 flex items-center justify-center bg-base-200 rounded-lg shrink-0">
            <.icon name={@provider.icon} class="w-5 h-5" />
          </span>
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <h2 class="text-lg font-semibold">{@provider.name}</h2>
              <%= cond do %>
                <% @name == nil -> %>
                <% @data["status"] == "connected" -> %>
                  <span class="badge badge-success badge-sm gap-1">
                    <.icon name="hero-check-circle" class="w-3 h-3" />
                    {gettext("Connected")}
                  </span>
                <% @data["status"] == "configured" -> %>
                  <span class="badge badge-warning badge-sm">{gettext("Not tested")}</span>
                <% @data["status"] == "error" -> %>
                  <span class="badge badge-error badge-sm">{gettext("Error")}</span>
                <% true -> %>
                  <span class="badge badge-ghost badge-sm">{gettext("Not connected")}</span>
              <% end %>
              <span :if={@data["external_account_id"]} class="text-sm text-base-content/60 truncate">
                · {@data["external_account_id"]}
              </span>
            </div>

            <div
              :if={
                @name != nil &&
                  (@data["validation_status"] || @data["last_validated_at"] ||
                     @data["connected_at"])
              }
              class="mt-1.5 flex flex-wrap gap-x-3 gap-y-1 text-xs items-center"
            >
              <span
                :if={@data["validation_status"] not in [nil, "", "ok"]}
                class={[
                  "inline-flex items-center gap-1",
                  if(@data["status"] == "error", do: "text-error", else: "text-warning")
                ]}
              >
                <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                {@data["validation_status"]}
              </span>
              <span
                :if={format_relative(@data["last_validated_at"])}
                class="text-base-content/50 inline-flex items-center gap-1"
              >
                <.icon name="hero-signal" class="w-3 h-3" />
                {gettext("Last tested")} {format_relative(@data["last_validated_at"])}
              </span>
              <span
                :if={
                  format_relative(@data["connected_at"]) &&
                    @data["connected_at"] != @data["last_validated_at"]
                }
                class="text-base-content/50 inline-flex items-center gap-1"
              >
                <.icon name="hero-link" class="w-3 h-3" />
                {gettext("Connected")} {format_relative(@data["connected_at"])}
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A single provider setup field, rendered from the field's `:type`.

  Credential-shaped fields stay `type="text"` on purpose — they're API keys /
  tokens, not site logins, and `type="password"` would trigger browsers'
  password-save heuristics. `:select`, `:textarea` and `:number` render as
  themselves; anything else falls back to a text input, so a provider that
  declares a type this component has never heard of still gets a usable field
  rather than a blank spot in the form.

  A `:select` with no stored value falls to the first option, so a provider
  should list its default first (that is how the SMTP `security` / `auth` /
  `verify_cert` fields keep their historical behavior on connections created
  before they existed).

  `:password` fields never echo a saved secret back into the markup (D011 —
  it used to round-trip in plain text on every `Edit` render). Resolution is
  three-way, in priority order:

    1. `typed_value` present — the operator just typed this (a dry-run Test
       re-render, `/new` flow) — show it verbatim, unmasked.
    2. No typed value, `saved_value` present, and the field is `:password` —
       show an empty input with the same "already configured" placeholder
       `Authorization` uses for its OAuth secrets (S009, `oauth_secret_placeholder/2`
       in `authorization.ex`) — same class of leak, same wording, so an
       operator doesn't see two phrasings of "a secret is already saved" in
       the same admin. An empty submit for an untouched password field is
       already read as "keep the existing credential" on the save side
       (`extract_setup_attrs/2` and its mirror in `MyIntegrationForm`), so
       this empty render is exactly what that save path expects.
    3. Otherwise — plain fields, or a `:password` field with nothing saved
       yet — show `saved_value` as before.
  """
  attr :field, :map, required: true
  attr :typed_value, :string, default: ""
  attr :saved_value, :string, default: ""

  def setup_field(assigns) do
    assigns =
      assigns
      |> assign(:value, setup_field_value(assigns))
      |> assign(:placeholder, setup_field_placeholder(assigns))
      |> assign(:required, setup_field_required?(assigns))

    ~H"""
    <div class="fieldset">
      <label class="label" for={"field-#{@field.key}"}>
        <span class="fieldset-legend">
          {@field.label}
          <span :if={@field.required} class="text-error">*</span>
        </span>
      </label>

      <%!-- Soft accesses on purpose: providers may be contributed by external
           modules through `integration_providers/0`, and a field map missing
           :type / :options / :placeholder must fall back to a text input, not
           take the whole form down with a KeyError. --%>
      <select
        :if={field_type(@field) == :select}
        name={@field.key}
        id={"field-#{@field.key}"}
        class="select w-full"
        required={@field.required}
      >
        <option
          :for={option <- Map.get(@field, :options) || []}
          value={option.value}
          selected={option.value == @value}
        >
          {option.label}
        </option>
      </select>

      <textarea
        :if={field_type(@field) == :textarea}
        name={@field.key}
        id={"field-#{@field.key}"}
        class="textarea w-full font-mono text-xs"
        rows="5"
        placeholder={@placeholder}
        required={@field.required}
        autocomplete="off"
      >{@value}</textarea>

      <input
        :if={field_type(@field) not in [:select, :textarea]}
        type={if field_type(@field) == :number, do: "number", else: "text"}
        name={@field.key}
        id={"field-#{@field.key}"}
        value={@value}
        class="input w-full"
        placeholder={@placeholder}
        required={@required}
        autocomplete="off"
      />

      <label :if={Map.get(@field, :help)} class="label">
        <span class="fieldset-label text-base-content/50">{@field.help}</span>
      </label>
    </div>
    """
  end

  defp field_type(field), do: Map.get(field, :type) || :text

  defp setup_field_value(%{typed_value: typed, saved_value: saved, field: field}) do
    cond do
      typed != "" -> typed
      field_type(field) == :password and saved != "" -> ""
      true -> saved
    end
  end

  # A masked secret renders empty, and empty means "keep the saved one" — so it
  # cannot also be `required`, or the browser refuses Save Changes until the
  # secret is typed again (e.g. when only a login next to it changed).
  defp setup_field_required?(%{typed_value: typed, saved_value: saved, field: field}) do
    # `== true`: a provider may leave `required` nil, which every other reader
    # takes as false.
    field.required == true and
      not (typed == "" and field_type(field) == :password and saved != "")
  end

  defp setup_field_placeholder(%{typed_value: typed, saved_value: saved, field: field}) do
    if typed == "" and field_type(field) == :password and saved != "" do
      # Same string as `Authorization`'s `oauth_secret_placeholder/2` (S009) —
      # not a call to it, since this core component shouldn't depend on a
      # LiveView module. The shared string is what matters: one wording for
      # "a secret is already saved", not two.
      gettext("A secret is already configured — leave blank to keep the current value")
    else
      Map.get(field, :placeholder) || ""
    end
  end

  @doc """
  Collapsible provider setup instructions (from the provider definition).
  `open` defaults closed; callers pass `open={@name == nil}` to keep it open
  during first-time setup.
  """
  attr :provider, :map, required: true
  attr :redirect_uri, :string, default: nil
  attr :open, :boolean, default: false

  def setup_instructions(assigns) do
    ~H"""
    <details
      :if={Map.get(@provider, :instructions, []) != []}
      class="card bg-base-200/50"
      open={@open}
    >
      <summary class="card-body cursor-pointer flex-row items-center gap-2 select-none">
        <.icon name="hero-book-open" class="w-4 h-4" />
        <h3 class="font-semibold text-base-content text-base">
          {gettext("Setup Instructions")}
        </h3>
        <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto text-base-content/40" />
      </summary>
      <div class="card-body pt-0 text-sm text-base-content/70 space-y-4">
        <div :for={{section, idx} <- Enum.with_index(Map.get(@provider, :instructions, []))}>
          <h4 class="font-semibold text-base-content">
            {idx + 1}. {section.title}
          </h4>
          <p :if={Map.get(section, :note)} class="text-xs text-base-content/50 mt-1 ml-2 mb-2">
            <span class="[&>strong]:font-semibold [&>strong]:text-base-content/70">
              {Phoenix.HTML.raw(
                render_markdown_inline(section.note, %{"redirect_uri" => @redirect_uri || ""})
              )}
            </span>
          </p>
          <ol class="list-decimal list-inside space-y-1 mt-1 ml-2">
            <li :for={{text, _detail} <- section.steps}>
              <span class="[&>a]:link [&>a]:link-primary [&>strong]:font-semibold [&>strong]:text-base-content">
                {Phoenix.HTML.raw(
                  render_markdown_inline(text, %{"redirect_uri" => @redirect_uri || ""})
                )}
              </span>
            </li>
          </ol>
        </div>
      </div>
    </details>
    """
  end
end
