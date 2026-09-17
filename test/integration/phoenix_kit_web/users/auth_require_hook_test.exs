defmodule PhoenixKitWeb.Users.AuthRequireHookTest do
  @moduledoc """
  Mount once, require per page: `{:phoenix_kit_require, requirement}`.

  A host that keeps public and signed-in pages in one `live_session` (so
  navigating between them stays on the socket) mounts the scope for the whole
  session and needs a per-page check. Before this, the only kit hooks that
  checked also mounted, and mounting a second time raised
  "existing hook :current_page already attached" — so the host wrote its own
  hook around private helpers it could not call.

  Pinned here: stacking no longer raises; the check-only hook enforces the
  same rules as the matching `ensure_*` hook without mounting again; and using
  it without a mounted scope is a loud wiring error, not a silent redirect of
  a signed-in user to the login page.
  """
  use PhoenixKit.DataCase, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias PhoenixKit.Users.Auth, as: AuthCtx
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  @view PhoenixKitWeb.Live.Users.Users

  defp socket(path \\ Routes.path("/account")) do
    %Socket{
      view: @view,
      assigns: %{__changed__: %{}, flash: %{}},
      private: %{
        connect_params: %{},
        connect_info: %{uri: URI.parse("http://localhost" <> path)},
        lifecycle: %Lifecycle{},
        live_temp: %{}
      },
      router: PhoenixKitWeb.Router
    }
  end

  defp confirmed_user do
    {:ok, user} =
      AuthCtx.register_user(%{
        email: "require_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = AuthCtx.admin_confirm_user(user)
    user
  end

  defp session_for(user), do: %{"user_token" => AuthCtx.generate_user_session_token(user)}

  defp mount(hooks, session, socket) do
    Enum.reduce_while(hooks, {:cont, socket}, fn hook, {:cont, socket} ->
      case Auth.on_mount(hook, %{}, session, socket) do
        {:cont, socket} -> {:cont, {:cont, socket}}
        {:halt, socket} -> {:halt, {:halt, socket}}
      end
    end)
  end

  defp current_page_hooks(socket) do
    socket.private.lifecycle.handle_params
    |> Enum.count(&(&1.id == :current_page))
  end

  describe "stacking" do
    test "mounting the scope and then an ensure hook no longer raises" do
      user = confirmed_user()

      assert {:cont, socket} =
               mount(
                 [:phoenix_kit_mount_current_scope, :phoenix_kit_ensure_authenticated_scope],
                 session_for(user),
                 socket()
               )

      assert current_page_hooks(socket) == 1
    end
  end

  describe "{:phoenix_kit_require, :authenticated}" do
    test "lets a signed-in user through without mounting again" do
      user = confirmed_user()

      assert {:cont, socket} =
               mount(
                 [:phoenix_kit_mount_current_scope, {:phoenix_kit_require, :authenticated}],
                 session_for(user),
                 socket()
               )

      assert socket.assigns.phoenix_kit_current_user.uuid == user.uuid
      assert current_page_hooks(socket) == 1
    end

    test "sends an anonymous visitor to log in, carrying return_to" do
      path = Routes.path("/account")

      assert {:halt, socket} =
               mount(
                 [:phoenix_kit_mount_current_scope, {:phoenix_kit_require, :authenticated}],
                 %{},
                 socket(path)
               )

      assert {:redirect, %{to: to}} = socket.redirected
      assert to =~ "/users/log-in"
      assert to =~ "return_to=" <> URI.encode_www_form(path)
    end

    test "without a mounted scope it is a wiring error, not a login bounce" do
      error =
        assert_raise ArgumentError, fn ->
          Auth.on_mount({:phoenix_kit_require, :authenticated}, %{}, %{}, socket())
        end

      assert error.message =~ ":phoenix_kit_mount_current_scope"
    end
  end

  describe "other requirements" do
    test ":owner turns away a signed-in non-owner, like the ensure hook" do
      user = confirmed_user()
      session = session_for(user)

      assert {:halt, via_require} =
               mount(
                 [:phoenix_kit_mount_current_scope, {:phoenix_kit_require, :owner}],
                 session,
                 socket()
               )

      assert {:halt, via_ensure} = mount([:phoenix_kit_ensure_owner], session, socket())

      assert via_require.assigns.flash["error"] == via_ensure.assigns.flash["error"]
      assert via_require.redirected == via_ensure.redirected
    end

    test ":admin turns away a user who holds no admin permission" do
      user = confirmed_user()

      assert {:halt, socket} =
               mount(
                 [:phoenix_kit_mount_current_scope, {:phoenix_kit_require, :admin}],
                 session_for(user),
                 socket(Routes.path("/admin/users"))
               )

      assert socket.assigns.flash["error"] =~ "permission"
    end

    test "an unknown requirement names the valid ones" do
      error =
        assert_raise ArgumentError, fn ->
          mount(
            [:phoenix_kit_mount_current_scope, {:phoenix_kit_require, :superuser}],
            %{},
            socket()
          )
        end

      assert error.message =~ ":authenticated, :owner, :admin"
    end
  end
end
