defmodule PhoenixKit.Dashboard.SharedPermissionKeyTest do
  @moduledoc """
  Several admin tabs gated on one custom permission key.

  Each tab registers the key it is gated on, once per tab and again on every
  registry reload. Registration always logged "re-registered, overriding
  previous metadata", so one app's key produced eight warnings per boot — noise
  that trains everyone to skip the log.

  Tabs sharing a key is normal and now stays quiet. What is still reported:
  tabs that disagree on `auto_grant_admin` (whether Admin holds the key by
  default must not depend on which tab loaded last), and a direct
  `register_custom_key/2` call re-registering a key. Which metadata wins is
  unchanged — the latest registration, as before.
  """
  use ExUnit.Case, async: false

  # Registration also tries to auto-grant the key to Admin, which needs a
  # database this unit test does not have; that failure is logged and
  # swallowed by design, and is not what these tests are about.
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias PhoenixKit.Dashboard.Registry
  alias PhoenixKit.Users.Permissions

  setup do
    Permissions.clear_custom_keys()
    on_exit(fn -> Permissions.clear_custom_keys() end)
    :ok
  end

  defp tab(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        label: "Tab #{id}",
        icon: "hero-cube",
        path: "devices/#{id}",
        permission: "devices"
      },
      attrs
    )
  end

  test "tabs sharing a key register it without a warning per tab" do
    log =
      capture_log([level: :warning], fn ->
        for id <- [:devices, :device_groups, :device_logs, :device_alerts] do
          Registry.auto_register_custom_permission(tab(id))
        end
      end)

    refute log =~ "re-registered", "four tabs on one key produced: #{log}"
    assert "devices" in Permissions.custom_keys()
  end

  test "a reload re-registers every tab silently" do
    Registry.auto_register_custom_permission(tab(:devices))

    log =
      capture_log([level: :warning], fn ->
        Registry.auto_register_custom_permission(tab(:devices))
      end)

    refute log =~ "re-registered"
  end

  test "the latest registration's metadata still wins" do
    Registry.auto_register_custom_permission(tab(:devices, %{label: "Devices"}))
    Registry.auto_register_custom_permission(tab(:device_logs, %{label: "Device logs"}))

    assert Permissions.custom_keys_map()["devices"].label == "Device logs"
  end

  test "tabs that disagree on auto_grant_admin are reported" do
    Registry.auto_register_custom_permission(tab(:devices, %{auto_grant_admin: true}))

    log =
      capture_log([level: :warning], fn ->
        Registry.auto_register_custom_permission(tab(:device_keys, %{auto_grant_admin: false}))
      end)

    assert log =~ "conflicting auto_grant_admin"
  end

  test "a direct re-registration still warns" do
    Permissions.register_custom_key("devices", label: "Devices")

    log =
      capture_log([level: :warning], fn ->
        Permissions.register_custom_key("devices", label: "Devices again")
      end)

    assert log =~ "re-registered"
  end
end
