defmodule PhoenixKitWeb.Live.Components.UserSettingsEtcherResetTest do
  @moduledoc """
  The "Annotation tools" section on /profile/settings: one button that
  puts Etcher back to how it ships.

  A user's annotation settings live in two places — the palette and ink
  the toolbar saves onto the user row, and Etcher's own how-you-work
  answers (dots, anchors, toolbar layout, per-tool colours) in the
  browser's localStorage. Clearing one without the other leaves someone
  half-fixed, so the reset does both: the row here, the browser through
  the pushed event the `EtcherReset` hook listens for.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Live.Components.UserSettings

  describe "resetting" do
    setup do
      {:ok, user} =
        Auth.register_user(%{
          email: "etcher-reset-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!"
        })

      {:ok, user} =
        Auth.merge_user_custom_fields(user, %{
          "etcher_colors" => ["#123456", "#abcdef"],
          "etcher_line_params" => %{"width" => 9, "dash" => "dotted"},
          # Something of the user's that has nothing to do with drawing.
          "phone" => "555-0100"
        })

      %{user: user}
    end

    defp reset(user) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, user: user, myself: nil},
        private: %{live_temp: %{}}
      }

      UserSettings.handle_event("reset_etcher_settings", %{}, socket)
    end

    test "clears the saved palette and ink", %{user: user} do
      {:noreply, socket} = reset(user)

      fresh = Auth.get_user_by_email(user.email)
      refute Map.has_key?(fresh.custom_fields, "etcher_colors")
      refute Map.has_key?(fresh.custom_fields, "etcher_line_params")
      assert socket.assigns.etcher_reset_message =~ "reset"
    end

    test "leaves everything else on the user alone", %{user: user} do
      {:noreply, _} = reset(user)

      fresh = Auth.get_user_by_email(user.email)

      assert fresh.custom_fields["phone"] == "555-0100",
             "a reset of the drawing tools must not touch the rest of the profile"
    end

    test "tells the browser to clear its half too", %{user: user} do
      {:noreply, socket} = reset(user)

      pushed = get_in(socket.private, [:live_temp, :push_events]) || []

      assert Enum.any?(pushed, fn
               ["phoenix_kit:etcher-reset" | _] -> true
               _ -> false
             end),
             "without the push, the toolbar layout and per-tool colours survive in localStorage"
    end

    test "a user who never saved anything resets cleanly", %{user: user} do
      {:noreply, _} = reset(user)
      fresh = Auth.get_user_by_email(user.email)

      # Second time: the keys are already gone. `delete_user_custom_field`
      # answers :not_found for those, which must read as "already reset".
      {:noreply, socket} = reset(fresh)
      assert socket.assigns.etcher_reset_message =~ "reset"
    end
  end
end

defmodule PhoenixKitWeb.Live.Components.UserSettingsEtcherSectionTest do
  @moduledoc "The DB-less half: the section is offered by default."

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Live.Components.UserSettings

  test "the annotation-tools section is in the default list" do
    assert :etcher in UserSettings.default_sections(),
           "/profile/settings renders the default list — a section missing from it is a " <>
             "section nobody can reach"
  end
end
