defmodule PhoenixKit.Migrations.RuntimeVersionExitTest do
  @moduledoc """
  `migrated_version_runtime/1` when the database connection EXITS.

  It is the read path behind `mix phoenix_kit.status`, the doctor and the
  update task's "what is installed?", and its contract is "0 when unknown".
  It rescued raises but not exits — and a connection pool whose owner is gone
  exits rather than raising. The update task then crashed instead of
  reporting the database unreachable (the suite caught this when a test ran
  just after one that had owned the sandbox in shared mode).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Migrations.Postgres

  defmodule ExitingRepo do
    def query(_sql, _params, _opts), do: exit({:shutdown, "owner exited"})
    def config, do: []
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :repo)
    Application.put_env(:phoenix_kit, :repo, ExitingRepo)

    # `ensure_repo_started/1` only asks whether a process has the repo's name.
    registered = Process.register(self(), ExitingRepo)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:phoenix_kit, :repo)
        value -> Application.put_env(:phoenix_kit, :repo, value)
      end
    end)

    assert registered
    :ok
  end

  test "an exiting connection reads as 'unknown' (0), not a crash" do
    assert Postgres.migrated_version_runtime(%{prefix: "public"}) == 0
  end
end
