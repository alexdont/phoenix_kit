defmodule PhoenixKitWeb.Live.Integrations.MyIntegrationFormChatLinkingTest do
  @moduledoc """
  Linking a Telegram chat that capture cannot reach.

  Capture only sees chats whose update is still in Telegram's ~24h queue, and
  before this it only ever looked at PRIVATE chats — so a bot added to a group
  had no path into `chat_ids` at all, and an id the operator already knew had
  nowhere to be typed. These drive the real LiveView events on
  `/profile/settings/integrations/:uuid`.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @group_id "-1001234567890"
  @dm_id "428897538"

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations")

    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("telegram", "shop bot", user.uuid, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(uuid, %{"bot_token" => "123:ABC"}, user.uuid,
        owner: {:user, user.uuid}
      )

    %{conn: log_in_user(conn, user), user: user, uuid: uuid}
  end

  defp edit_path(uuid), do: Routes.path("/profile/settings/integrations/#{uuid}")

  defp linked_ids(uuid, user) do
    [conn] = Integrations.list_connections("telegram", owner: {:user, user.uuid})
    ^uuid = conn.uuid
    conn.data["chat_ids"] || []
  end

  describe "linking a chat by id" do
    test "a group id typed by hand is linked", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      html = render_submit(view, "link_chat", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == [@group_id]
      assert html =~ @group_id
    end

    test "the linked chat is labelled as a group, not shown as a bare number", %{
      conn: conn,
      uuid: uuid
    } do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      html = render_submit(view, "link_chat", %{"chat_id" => @group_id})

      assert html =~ "Group"
    end

    test "a junk id is refused and nothing is linked", %{conn: conn, uuid: uuid, user: user} do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      html = render_submit(view, "link_chat", %{"chat_id" => "not an id"})

      assert linked_ids(uuid, user) == []
      assert html =~ "alert-error"
    end

    test "linking the same chat twice does not duplicate it", %{
      conn: conn,
      uuid: uuid,
      user: user
    } do
      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_submit(view, "link_chat", %{"chat_id" => @group_id})
      render_submit(view, "link_chat", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == [@group_id]
    end
  end

  describe "unlinking one chat" do
    test "removes only the named chat", %{conn: conn, uuid: uuid, user: user} do
      {:ok, _} =
        Integrations.save_setup(uuid, %{"chat_ids" => [@dm_id, @group_id]}, user.uuid,
          owner: {:user, user.uuid}
        )

      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "unlink_chat", %{"chat_id" => @group_id})

      assert linked_ids(uuid, user) == [@dm_id]
    end
  end

  describe "metadata follows the linked chats" do
    test "unlinking a chat drops what was remembered about it", %{
      conn: conn,
      uuid: uuid,
      user: user
    } do
      {:ok, _} =
        Integrations.save_setup(
          uuid,
          %{
            "chat_ids" => [@dm_id, @group_id],
            "chat_meta" => %{
              @dm_id => %{"type" => "private", "title" => nil},
              @group_id => %{"type" => "supergroup", "title" => "Shop"}
            }
          },
          user.uuid,
          owner: {:user, user.uuid}
        )

      {:ok, view, _html} = live(conn, edit_path(uuid))

      render_click(view, "unlink_chat", %{"chat_id" => @group_id})

      [conn_row] = Integrations.list_connections("telegram", owner: {:user, user.uuid})

      assert Map.keys(conn_row.data["chat_meta"]) == [@dm_id]
    end
  end

  describe "the group is discoverable at all" do
    test "the card tells the operator the command that links a group", %{conn: conn, uuid: uuid} do
      # Telegram privacy mode means plain chatter in a group never reaches the
      # bot: without the command spelled out, pressing Test in a group is a
      # coin flip. This assertion is the whole point of the UI change.
      {:ok, _view, html} = live(conn, edit_path(uuid))

      assert html =~ "/start@"
    end
  end
end
