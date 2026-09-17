defmodule PhoenixKit.ObanQueues do
  @moduledoc """
  The Oban queues PhoenixKit and its modules need, declared where the work is
  defined rather than hand-copied into a host's config.

  ## Why

  Oban only runs jobs from queues the node lists. A job inserted into a queue
  nothing runs sits `available` forever, and the feature looks fine until
  someone counts the rows. Until now the list lived in two places in core — the
  installer's block and the updater's backfill — which had already drifted
  (the updater wrote `shop_imports: 2` while the module's own docs asked for
  5), and a module had no way to declare a queue at all, so its install docs
  told the host to edit `config.exs` by hand and its workers ended up sharing
  `default`.

  ## How it fits together

    * A module declares its queues with the optional `oban_queues/0` callback
      of `PhoenixKit.Module`. Core declares its own here (`core_queues/0`), so
      there is one mechanism, not a module mechanism beside a hardcoded list.
    * `mix phoenix_kit.install` writes every declared queue into a new Oban
      block; `mix phoenix_kit.update` adds the ones an existing block is
      missing. **Neither ever changes a limit the host already has** — a number
      is the module author's suggestion until it lands in `config.exs`, and
      the host's from then on. A node that runs no queues (`queues: false` or
      `[]`) is left alone.
    * `mix phoenix_kit.doctor` reports declared queues the running config is
      missing, and modules that declare one queue with different limits. The
      application logs the same at boot, once.

  Queues are **per node**: a limit is how many jobs of that queue one node runs
  at a time. Split work by what it is — interactive work a person is waiting
  for, batch work nobody watches — rather than one queue per package, so a
  400-item import cannot hold up an image someone just asked for.

  ## Declaring

      @impl PhoenixKit.Module
      def oban_queues do
        [
          image_generation: [limit: 3, kind: :interactive],
          catalogue_import: 2
        ]
      end

  A bare integer is the limit. `:kind` (`:interactive` or `:batch`) is
  advisory — it explains the number in the doctor's output and the generated
  config, and changes nothing at runtime.
  """

  require Logger

  alias PhoenixKit.ModuleDiscovery
  alias PhoenixKit.ModuleRegistry

  @typedoc "One declared queue."
  @type spec :: %{
          name: atom(),
          limit: pos_integer(),
          kind: :interactive | :batch | nil,
          owner: module() | :core | :legacy
        }

  @typedoc "Two declarations of one queue that disagree on the limit."
  @type conflict :: %{name: atom(), kept: spec(), ignored: spec()}

  @valid_name ~r/^[a-z][a-z0-9_]*$/

  # Core's own queues ("module zero").
  @core_queues [
    default: [limit: 10],
    file_processing: [limit: 20, kind: :batch],
    scheduled_jobs: [limit: 1, kind: :batch],
    sitemap: [limit: 5, kind: :batch],
    notifications: [limit: 10, kind: :interactive]
  ]

  # Queues core used to write on behalf of feature modules, before a module
  # could declare its own. They stay until each module ships `oban_queues/0`
  # and hosts have upgraded to it: dropping one first would leave a fresh
  # install without the queue its module's jobs go to. A module that declares
  # one of these takes it over — its declaration wins over this entry without
  # being reported as a conflict.
  @legacy_module_queues [
    posts: [limit: 10],
    newsletters_delivery: [limit: 10],
    catalogue_pdf: [limit: 2, kind: :batch],
    shop_imports: [limit: 2, kind: :batch]
  ]

  # The package whose jobs each fallback queue carries. The installer writes
  # every fallback regardless (an idle queue costs nothing, and a package added
  # later finds its queue); only the warnings ask whether the package is there.
  @legacy_queue_apps %{
    posts: :phoenix_kit_posts,
    newsletters_delivery: :phoenix_kit_newsletters,
    catalogue_pdf: :phoenix_kit_catalogue,
    shop_imports: :phoenix_kit_ecommerce
  }

  @doc "Core's own queues."
  @spec core_queues() :: [spec()]
  def core_queues, do: normalize(@core_queues, :core)

  @doc "The fallback entries kept for modules that do not declare their queues yet."
  @spec legacy_module_queues() :: [spec()]
  def legacy_module_queues, do: normalize(@legacy_module_queues, :legacy)

  @doc """
  Every queue to configure: core's, then each module's, then the legacy
  fallbacks no module has taken over — one entry per name.

  `modules` defaults to the registered modules when the registry is running,
  and to a `.beam` scan otherwise (the install and update tasks run before it).
  Returns the resolved list and any conflicts found on the way.
  """
  @spec resolve([module()] | nil) :: {[spec()], [conflict()]}
  def resolve(modules \\ nil) do
    modules = modules || installed_modules()

    module_specs =
      modules
      |> Enum.uniq()
      |> Enum.sort_by(&inspect/1)
      |> Enum.flat_map(&module_queues/1)

    {resolved, conflicts} = merge(core_queues() ++ module_specs, [])

    declared = MapSet.new(resolved, & &1.name)
    fallbacks = Enum.reject(legacy_module_queues(), &MapSet.member?(declared, &1.name))

    {resolved ++ fallbacks, conflicts}
  end

  @doc """
  The declared queues a node must actually run: `declared` without the
  fallback entries whose package is not installed. Warning that no one runs
  `catalogue_pdf` on a site without the catalogue would send its owner off to
  configure a queue nothing can enqueue into.

  `installed?` answers for an OTP application; it defaults to whether the
  application can be loaded — whether it is on the code path, as every
  dependency of the host is, whether or not it has started yet.
  """
  @spec required([spec()], (atom() -> boolean())) :: [spec()]
  def required(declared, installed? \\ &app_installed?/1) do
    Enum.filter(declared, fn
      %{owner: :legacy, name: name} ->
        case Map.fetch(@legacy_queue_apps, name) do
          {:ok, app} -> installed?.(app)
          :error -> true
        end

      _ ->
        true
    end)
  end

  @doc "The resolved queues only — see `resolve/1`."
  @spec declared([module()] | nil) :: [spec()]
  def declared(modules \\ nil), do: modules |> resolve() |> elem(0)

  @doc """
  The declared queues a node's Oban config does not list.

  `oban_config` is the keyword list given to Oban. A node that runs no queues
  (`queues: false` or `[]`) is missing nothing — it is a web-only node by
  choice — and so is one whose config is not a keyword list this function can
  read (a host building it at runtime from environment variables).
  """
  @spec missing(keyword() | nil, [spec()]) :: [spec()]
  def missing(oban_config, declared) when is_list(oban_config) do
    case Keyword.get(oban_config, :queues, []) do
      queues when is_list(queues) and queues != [] ->
        configured = MapSet.new(queues, fn {name, _} -> to_string(name) end)
        Enum.reject(declared, &MapSet.member?(configured, Atom.to_string(&1.name)))

      _ ->
        []
    end
  end

  def missing(_oban_config, _declared), do: []

  @doc """
  One line describing a conflict, for logs and the doctor.
  """
  @spec describe_conflict(conflict()) :: String.t()
  def describe_conflict(%{name: name, kept: kept, ignored: ignored}) do
    "queue #{inspect(name)} is declared with limit #{kept.limit} by #{owner_label(kept.owner)} " <>
      "and #{ignored.limit} by #{owner_label(ignored.owner)}; #{kept.limit} is used"
  end

  @doc false
  def owner_label(:core), do: "PhoenixKit"
  def owner_label(:legacy), do: "PhoenixKit (on behalf of a module)"
  def owner_label(module), do: inspect(module)

  @doc """
  Logs, once per boot, any declared queue the running Oban instance does not
  run. Best-effort by design: it runs after the host's supervision tree has
  had time to start Oban, reads only what Oban reports, and never raises.
  """
  @spec warn_about_missing_queues(keyword()) :: :ok
  def warn_about_missing_queues(opts \\ []) do
    oban_name = Keyword.get(opts, :oban, Oban)

    with true <- Code.ensure_loaded?(Oban),
         pid when is_pid(pid) <- Oban.whereis(oban_name),
         %{testing: :disabled, queues: queues} <- Oban.config(oban_name) do
      case boot_findings(queues, resolve()) do
        {[], []} -> :ok
        {missing, conflicts} -> log_findings(missing, conflicts)
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  # Pure: what the boot check reports for the queues Oban runs — the required
  # queues it does not run, and the conflicts `resolve/1` found.
  @spec boot_findings(list(), {[spec()], [conflict()]}, (atom() -> boolean())) ::
          {[spec()], [conflict()]}
  def boot_findings(queues, {declared, conflicts}, installed? \\ &app_installed?/1) do
    {missing([queues: queues], required(declared, installed?)), conflicts}
  end

  # Loading reads the `.app` file only; nothing starts. A package that is not
  # a dependency is not on the code path and fails to load.
  defp app_installed?(app) do
    case Application.load(app) do
      :ok -> true
      {:error, {:already_loaded, _}} -> true
      {:error, _} -> false
    end
  end

  defp log_findings(missing, conflicts) do
    if missing != [] do
      names = Enum.map_join(missing, ", ", &"#{&1.name} (#{owner_label(&1.owner)})")

      Logger.warning(
        "[PhoenixKit] Oban is not running these queues, so their jobs will wait forever: " <>
          "#{names}. Run `mix phoenix_kit.update` to add them to your Oban config, " <>
          "or add them by hand. A node that should run no jobs can set `queues: false`."
      )
    end

    Enum.each(conflicts, &Logger.warning("[PhoenixKit] " <> describe_conflict(&1)))
    :ok
  end

  ## Internals

  defp installed_modules do
    case ModuleRegistry.all_modules() do
      [] -> ModuleDiscovery.discover_external_modules()
      modules -> modules
    end
  rescue
    _ -> []
  end

  defp module_queues(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :oban_queues, 0) do
      module.oban_queues() |> normalize(module)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKit] #{inspect(module)}.oban_queues/0 failed: #{Exception.message(error)}"
      )

      []
  end

  @doc false
  # Accepts `[name: limit]` and `[name: [limit: n, kind: k]]`; drops (with a
  # warning) anything else, so one malformed declaration cannot take the
  # installer or the boot check down with it.
  @spec normalize(term(), module() | :core | :legacy) :: [spec()]
  def normalize(declared, owner) when is_list(declared) do
    Enum.flat_map(declared, fn entry ->
      case normalize_entry(entry, owner) do
        {:ok, spec} ->
          [spec]

        :error ->
          Logger.warning(
            "[PhoenixKit] ignoring invalid Oban queue declaration #{inspect(entry)} " <>
              "from #{owner_label(owner)}: expected `name: limit` or `name: [limit: n]`"
          )

          []
      end
    end)
  end

  def normalize(declared, owner) do
    Logger.warning(
      "[PhoenixKit] #{owner_label(owner)} declared Oban queues as #{inspect(declared)}; " <>
        "expected a keyword list"
    )

    []
  end

  defp normalize_entry({name, limit}, owner) when is_integer(limit),
    do: normalize_entry({name, [limit: limit]}, owner)

  defp normalize_entry({name, opts}, owner) when is_atom(name) and is_list(opts) do
    limit = Keyword.get(opts, :limit)
    kind = Keyword.get(opts, :kind)

    if Regex.match?(@valid_name, Atom.to_string(name)) and is_integer(limit) and limit > 0 and
         kind in [nil, :interactive, :batch] do
      {:ok, %{name: name, limit: limit, kind: kind, owner: owner}}
    else
      :error
    end
  end

  defp normalize_entry(_entry, _owner), do: :error

  # First declaration of a name wins (core first, then modules in a stable
  # order); a later one with a different limit is a conflict, the same limit
  # is simply a shared queue.
  defp merge(specs, acc) do
    {kept, conflicts} =
      Enum.reduce(specs, {%{}, acc}, fn spec, {kept, conflicts} ->
        case Map.fetch(kept, spec.name) do
          :error ->
            {Map.put(kept, spec.name, spec), conflicts}

          {:ok, %{limit: limit}} when limit == spec.limit ->
            {kept, conflicts}

          {:ok, existing} ->
            {kept, [%{name: spec.name, kept: existing, ignored: spec} | conflicts]}
        end
      end)

    ordered =
      specs
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.map(&Map.fetch!(kept, &1))

    {ordered, Enum.reverse(conflicts)}
  end
end
