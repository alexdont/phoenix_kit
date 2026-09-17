defmodule PhoenixKit.Dashboard.RegistryUpdateModeTest do
  @moduledoc """
  Registry writes when the registry is not running.

  `mix phoenix_kit.update` boots the host app with a reduced supervision tree
  that leaves the dashboard registry out, then runs the host's own start code.
  A host that hides an admin tab the way PhoenixKit 1.7 documented — a
  `Registry.unregister_tab/1` at boot — used to hit a `GenServer.call` to a
  process that isn't there. That is an exit, uncatchable by `rescue`, so the
  update died *before migrating*: the operator saw a crash and the database
  quietly stayed behind.

  In update mode the write is skipped. In a normal boot the same call must
  still fail loudly, because there it means a genuine ordering bug.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Registry

  setup do
    previous = Application.get_env(:phoenix_kit, :update_mode)
    running? = is_pid(Process.whereis(Registry))

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:phoenix_kit, :update_mode)
        value -> Application.put_env(:phoenix_kit, :update_mode, value)
      end
    end)

    %{registry_running?: running?}
  end

  describe "update mode, registry absent" do
    test "a write is skipped instead of exiting", %{registry_running?: running?} do
      refute running?, "this suite must not start the registry, or this test proves nothing"

      Application.put_env(:phoenix_kit, :update_mode, true)

      assert Registry.unregister_tab(:admin_jobs) == :ok
      assert Registry.update_tab_badge(:admin_users, nil) == :ok
      assert Registry.unregister(:my_app) == :ok
    end
  end

  describe "normal boot, registry absent" do
    test "a write still fails loudly", %{registry_running?: running?} do
      refute running?, "this suite must not start the registry, or this test proves nothing"

      Application.put_env(:phoenix_kit, :update_mode, false)

      assert catch_exit(Registry.unregister_tab(:admin_jobs)),
             "outside update mode this is an ordering bug and must not be swallowed"
    end
  end
end
