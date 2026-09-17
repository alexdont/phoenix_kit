defmodule PhoenixKit.Install.Common do
  @moduledoc """
  Common utilities shared between PhoenixKit installation and update tasks.

  This module provides shared functionality for:
  - Timestamp generation
  - Version formatting
  - Status checking
  - Migration detection
  - Registering PhoenixKit's Mix compilers in a host's `mix.exs`
  """

  # Igniter is optional (see mix.exs) and this module cannot be guarded away
  # like the `PhoenixKit.Install.*` helpers — `mix phoenix_kit.status` and
  # friends call its non-igniter half. The shim silences the undefined-module
  # warnings for the igniter-only functions on a build without igniter.
  use PhoenixKit.Install.IgniterCompat

  alias PhoenixKit.Config
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.Helpers

  @doc """
  Ensures every atom in `compiler_names` is present in the host's `mix.exs`
  `project/0` `:compilers` list — in ONE `Igniter.Project.MixProject.update/4`
  call across every compiler PhoenixKit registers.

  This must be a single call spanning all of them, not one call per compiler.
  `Igniter.Code.List.prepend_new_to_list/2` only understands a literal list
  AST. Registering against an absent `:compilers` key has to produce `atoms
  ++ Mix.compilers()` (a `++` call, not a literal list — `Mix.compilers()` is
  a live call that can't be flattened at install time). A SECOND, separate
  `Igniter.Project.MixProject.update/4` call touching the same key then lands
  on that `++` node instead of a list, and `prepend_new_to_list/2` silently
  fails into a `{:warning, ...}` that's easy to miss in the wall of `mix
  phoenix_kit.update`/`mix phoenix_kit.install` output — so the second
  compiler never actually gets registered even though the run reports
  success. This is not hypothetical: it's exactly how a production host ended
  up with `:phoenix_kit_css_sources` registered (added first) but
  `:phoenix_kit_js_sources` silently missing (added second, in a separate
  call) across many `phoenix_kit.update` runs — so PhoenixKit's own JS hook
  fixes never reached the browser.

  Also repairs a `:compilers` value an affected host is already stuck with in
  that broken `[some_atom] ++ Mix.compilers()` shape: descends into the
  literal list on the left of `++` and prepends there instead of bailing.
  """
  def ensure_compilers_registered(igniter, compiler_names) when is_list(compiler_names) do
    Igniter.Project.MixProject.update(igniter, :project, [:compilers], fn
      nil ->
        # No :compilers key yet — must keep the defaults, so prepend to
        # Mix.compilers() rather than replacing the whole list.
        {:ok, {:code, quote(do: unquote(compiler_names) ++ Mix.compilers())}}

      zipper ->
        zipper
        |> resolve_literal_compilers_list()
        |> case do
          {:ok, list_zipper} -> prepend_missing(list_zipper, compiler_names)
          :error -> :error
        end
        |> case do
          {:ok, zipper} ->
            {:ok, zipper}

          :error ->
            {:warning,
             "Could not add #{inspect(compiler_names)} to compilers in mix.exs — " <>
               "please add them manually: compilers: #{inspect(compiler_names)} ++ Mix.compilers()"}
        end
    end)
  end

  # The zipper is either already a literal list (`compilers: [:a, :b]`), or
  # `[:a] ++ Mix.compilers()` (the shape THIS module itself produces on first
  # registration, or that a foreign tool produced the same way) — descend
  # into the literal list on the left of `++` so callers can prepend into it.
  # Anything else (a bare variable, a function call returning a list, etc.)
  # is refused rather than guessed at.
  defp resolve_literal_compilers_list(zipper) do
    cond do
      Igniter.Code.List.list?(zipper) ->
        {:ok, zipper}

      Igniter.Code.Function.function_call?(zipper, :++, 2) ->
        Igniter.Code.Function.move_to_nth_argument(zipper, 0)

      true ->
        :error
    end
  end

  defp prepend_missing(zipper, names) do
    Enum.reduce_while(names, {:ok, zipper}, fn name, {:ok, zipper} ->
      case Igniter.Code.List.prepend_new_to_list(zipper, name) do
        {:ok, zipper} -> {:cont, {:ok, zipper}}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc """
  Generates timestamp in Ecto migration format.

  ## Examples

      iex> PhoenixKit.Install.Common.generate_timestamp()
      "20250908123045"
  """
  def generate_timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  @doc """
  Pads a number with leading zero if less than 10.

  ## Examples

      iex> PhoenixKit.Install.Common.pad(5)
      "05"

      iex> PhoenixKit.Install.Common.pad(12)
      "12"
  """
  def pad(i) when i < 10, do: <<?0, ?0 + i>>
  def pad(i), do: to_string(i)

  @doc """
  Pads version number for consistent naming.

  ## Examples

      iex> PhoenixKit.Install.Common.pad_version(1)
      "01"

      iex> PhoenixKit.Install.Common.pad_version(15)
      "15"
  """
  def pad_version(version) when version < 10, do: "0#{version}"
  def pad_version(version), do: to_string(version)

  @doc """
  Checks the current installation status for a given prefix.

  Returns one of:
  - `{:not_installed}` - the database is reachable and has no PhoenixKit install at the prefix
  - `{:current_version, version}` - PhoenixKit is installed with given version
  - `{:unknown_version}` - installed, but the version comment is missing or
    unreadable. Distinct from both of the above **because both of them route a
    caller somewhere that writes**: "not installed" to a fresh install, and a
    fabricated low version to the 1.7.x bridge, whose backfill invents uuids for
    still-NULL tracked columns and then deletes the rows that match no user.
    Callers must surface this and stop.
  - `{:unreachable, reason}` - the database cannot be queried, so the install
    state is UNKNOWN — callers must not treat this as "not installed"

  This list is the contract callers pattern-match against, so it is exhaustive
  on purpose. `{:unknown_version}` was added after the other three, and the one
  consumer whose clause set was not extended with it — `StatusReport.next_action/3`
  — crashed `mix phoenix_kit.status` with a `FunctionClauseError` until it was.

  ## Parameters
  - `prefix` - Database schema prefix (default: "public")

  ## Examples

      iex> PhoenixKit.Install.Common.check_installation_status("public")
      {:current_version, 3}

      iex> PhoenixKit.Install.Common.check_installation_status("auth")
      {:not_installed}
  """
  def check_installation_status(prefix \\ "public") do
    # Fail fast on an invalid prefix — it is interpolated into SQL in the
    # fallback paths below, and the migration chain would reject it anyway.
    Helpers.validate_prefix!(prefix)

    # Use the same version detection logic as the migration system
    opts = %{
      prefix: prefix,
      escaped_prefix: String.replace(prefix, "'", "\\'")
    }

    try do
      current_version = Postgres.migrated_version_runtime(opts)

      cond do
        # `migrated_version_runtime/1` is the DISPLAY twin: for a table with no
        # comment it deliberately guesses V01 so `status`, `doctor` and the admin
        # UI keep rendering, and warns that the migrator will refuse. That design
        # is right for a read path — but THIS function feeds the update task,
        # which acts on the value, and V01 is below the floor, so the guess came
        # back out of it as "install the 1.7.x bridge first": exactly the
        # destructive advice the warning promises will not be given.
        #
        # A bare 1 is therefore re-asked through the strict reader, which can
        # tell "the comment says 1" from "there is no comment". Only that one
        # value is re-checked; every other version is taken as read.
        current_version == 1 and not comment_literally_says_one?(opts) ->
          {:unknown_version}

        current_version > 0 ->
          {:current_version, current_version}

        true ->
          # Primary detection failed, try alternative detection methods
          check_alternative_version_detection(prefix, opts)
      end
    rescue
      error ->
        # Database error - genuine connection/query failure
        IO.puts("Warning: Database connection failed during version detection: #{inspect(error)}")
        # Try alternative methods before giving up
        check_alternative_version_detection(prefix, opts)
    end
  end

  # Alternative version detection when primary method fails
  #
  # Migration FILES existing in the project say nothing about what is
  # installed in the DATABASE at this prefix. This used to fall back to a
  # fabricated {:current_version, 1} whenever migration files were present,
  # which made `mix phoenix_kit.update` generate a from-scratch v01→vN
  # migration into the wrong schema when the prefix was misresolved (e.g.
  # installed under a custom prefix but checked at "public"). Report
  # honestly instead.
  defp check_alternative_version_detection(_prefix, opts) do
    case try_direct_database_version_check(opts) do
      version when is_integer(version) and version > 0 ->
        {:current_version, version}

      :unknown_version ->
        # Installed, but the one record of WHAT is installed is gone. Neither
        # "not installed" nor a version: both send the operator somewhere that
        # writes. Callers surface this and stop.
        {:unknown_version}

      _ ->
        # "No version found" is only "not installed" when we can actually
        # reach the database — a down DB must not masquerade as an absent
        # install (the update task drives migration generation off this).
        case database_reachable?() do
          :ok -> {:not_installed}
          {:error, reason} -> {:unreachable, reason}
        end
    end
  end

  # A comment that is not a plain integer is corruption, not a version. The
  # migrator's `parse_version_comment!/2` raises with restamp instructions; this
  # is the non-raising twin for the tasks that report rather than migrate — a
  # bare `String.to_integer/1` here would crash `mix phoenix_kit.update` on
  # exactly the hand-edited comments (`'v164'`, `' 164'`) the migrator documents.
  defp parse_version_comment(version) when is_binary(version) do
    case Integer.parse(String.trim(version)) do
      {n, ""} when n > 0 -> n
      _ -> :unknown_version
    end
  end

  defp database_reachable? do
    case Config.get(:repo, nil) do
      nil ->
        {:error, :no_repo_configured}

      repo ->
        case repo.query("SELECT 1", [], log: false) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    error -> {:error, error}
  catch
    # A dead pool exits rather than raising.
    :exit, reason -> {:error, reason}
  end

  # Try direct database connection (similar to what status command does)
  # Only an affirmative "the comment reads 1" may produce `{:current_version, 1}`.
  # Everything else — no comment, an unparseable one, a failed query, a repo this
  # function cannot resolve — is unknown.
  #
  # Fail-CLOSED, because the two mistakes are not equally bad. A genuine V01
  # install sent to `doctor` first loses a minute, and `doctor` then tells it the
  # truth. A CURRENT database sent to the 1.7.x bridge has its still-NULL tracked
  # columns backfilled with invented uuids and the rows deleted for matching no
  # user.
  #
  # The earlier form asked `... == :unknown_version`, which only fires when the
  # re-check positively reports "no comment" — so every way of FAILING to answer
  # fell through to the destructive branch. That is not hypothetical:
  # `try_direct_database_version_check/1` resolves the repo with
  # `Config.get(:repo, nil)` alone, while `migrated_version_runtime/1` — the call
  # that produced the 1 in the first place — resolves it through
  # `Postgres.get_repo_with_fallback/0`, which additionally starts the app and
  # auto-detects from the Mix project. On a host that never sets
  # `config :phoenix_kit, repo:` and relies on that auto-detection, the first
  # returns nil and the second returns the repo — so the guard silently did not
  # fire on precisely the state it was written for. Same shape as the twin mixup
  # this guard already exists to correct, one level down.
  defp comment_literally_says_one?(opts) do
    try_direct_database_version_check(opts) == 1
  end

  defp try_direct_database_version_check(opts) do
    # Try to get the repo from application config first (same as status command)
    repo = Config.get(:repo, nil)

    if repo do
      escaped_prefix = Map.fetch!(opts, :escaped_prefix)
      query_version_directly(repo, escaped_prefix)
    else
      0
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # Direct version query (simplified version of the runtime check)
  defp query_version_directly(repo, escaped_prefix) do
    # Check if phoenix_kit table exists first
    table_check =
      "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'phoenix_kit' AND table_schema = $1)"

    case repo.query(table_check, [escaped_prefix], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, get version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = $1
        """

        case repo.query(version_query, [escaped_prefix], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) ->
            parse_version_comment(version)

          _ ->
            # A table with no comment is NOT "version 1". That guess is what the
            # migrator refuses outright, in its own words: it "would route a
            # possibly CURRENT database to the 1.7.x bridge, whose backfill
            # overwrites still-NULL tracked columns with freshly generated uuids
            # pointing at nothing" (`Postgres.migrated_version/1`).
            #
            # Reported as 1, it lands below the floor, and `phoenix_kit.update`
            # tells the operator to install that very bridge — so the two halves
            # of the same release gave opposite instructions for one state, and
            # the destructive one was the one seen first. `:unknown_version` is
            # distinguishable from every real version, and the update task routes
            # it to doctor + restamp instead.
            :unknown_version
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  @doc """
  Finds existing PhoenixKit migrations in the project.

  Returns a list of migration file paths.
  """
  def find_existing_phoenix_kit_migrations do
    if File.exists?("priv/repo/migrations") do
      "priv/repo/migrations"
      |> File.ls!()
      |> Enum.filter(&phoenix_kit_migration?/1)
      |> Enum.map(&Path.join("priv/repo/migrations", &1))
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Checks if a filename matches PhoenixKit migration pattern.

  ## Examples

      iex> PhoenixKit.Install.Common.phoenix_kit_migration?("20250908_add_phoenix_kit_tables.exs")
      true

      iex> PhoenixKit.Install.Common.phoenix_kit_migration?("20250908_create_users.exs")
      false
  """
  def phoenix_kit_migration?(filename) do
    (String.contains?(filename, "phoenix_kit") ||
       String.contains?(filename, "add_phoenix_kit") ||
       String.contains?(filename, "upgrade_phoenix_kit") ||
       String.contains?(filename, "update_phoenix_kit")) &&
      String.ends_with?(filename, ".exs")
  end

  @doc """
  Describes what changed between versions.

  ## Parameters
  - `from_version` - Starting version number
  - `to_version` - Target version number

  ## Returns
  String describing the changes between versions.
  """
  def describe_version_changes(from_version, to_version) when from_version >= to_version do
    "- No changes (already up to date)"
  end

  def describe_version_changes(from_version, to_version) do
    case version_headings(from_version, to_version) do
      [] -> "- Various improvements and new features"
      headings -> Enum.map_join(headings, "\n", &"- #{&1}")
    end
  end

  # The per-version headings from `PhoenixKit.Migrations.Postgres`'s moduledoc —
  # `### V160 - Settings value widened to TEXT` and friends.
  #
  # This used to answer "Various improvements and new features", which tells a
  # host nothing about whether to upgrade now or next sprint. The headings are
  # already written for every version and are the authoritative account of what
  # a migration does, so reading them costs nothing to maintain and cannot drift
  # from the versions `--status` reports (they are the same V-numbers).
  #
  # Falls back to the generic line when docs are unavailable — a release built
  # with `strip_beams` has none, and this is a diagnostic, not a contract.
  defp version_headings(from_version, to_version) do
    case Code.fetch_docs(Postgres) do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} ->
        ~r/^###\s+V(\d+)\s+-\s+(.+)$/m
        |> Regex.scan(moduledoc)
        |> Enum.map(fn [_, version, title] -> {String.to_integer(version), title} end)
        |> Enum.filter(fn {version, _} -> version > from_version and version <= to_version end)
        |> Enum.sort()
        |> Enum.map(fn {version, title} ->
          "V#{version}: #{title |> String.replace(~r/\s*⚡ LATEST\s*$/, "") |> String.trim()}"
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Gets current PhoenixKit version from migrations system.
  """
  def current_version, do: Postgres.current_version()

  @doc """
  Gets migrated version for given prefix.

  ## Parameters
  - `prefix` - Database schema prefix
  """
  def migrated_version(prefix \\ "public") do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
    Postgres.migrated_version_runtime(opts)
  rescue
    e in ArgumentError -> reraise(e, __STACKTRACE__)
    _ -> 0
  end

  @doc """
  Checks if an update is needed from current to target version.

  ## Parameters
  - `prefix` - Database schema prefix
  - `force` - Force update even if already up to date

  ## Returns
  - `{:up_to_date, current_version}` - Already up to date
  - `{:update_needed, current_version, target_version}` - Update available
  - `{:not_installed}` - PhoenixKit not installed
  - `{:unknown_version}` - installed, version comment unreadable; neither up to
    date nor updatable, and answering either would send the caller somewhere
    that writes (see `check_installation_status/1`)
  - `{:unreachable, reason}` - database cannot be queried (state unknown)

  > #### No callers in this repo {: .info}
  >
  > Public API for host applications; nothing in `lib/` calls it today, so the
  > clause set here is not exercised by the suite. Check it by hand when adding
  > a state to `check_installation_status/1`.
  """
  def check_update_needed(prefix \\ "public", force \\ false) do
    case check_installation_status(prefix) do
      {:not_installed} ->
        {:not_installed}

      {:unreachable, reason} ->
        {:unreachable, reason}

      # Passed through rather than folded into one of the others: an install
      # whose version is unreadable neither needs an update nor is up to date,
      # and answering either would send a caller somewhere that writes.
      {:unknown_version} ->
        {:unknown_version}

      {:current_version, current_version} ->
        target_version = current_version()

        cond do
          current_version >= target_version && !force ->
            {:up_to_date, current_version}

          current_version < target_version || force ->
            {:update_needed, current_version, target_version}

          true ->
            {:up_to_date, current_version}
        end
    end
  end
end
