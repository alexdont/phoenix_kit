defmodule PhoenixKit.Integrations.Telegram.ChatLinkTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.Telegram.ChatLink

  defp message_update(id, chat) do
    %{"update_id" => id, "message" => %{"chat" => chat, "text" => "/start"}}
  end

  describe "capturable_chats/1" do
    test "captures the private chat a /start came from" do
      updates = [message_update(1, %{"id" => 428_897_538, "type" => "private"})]

      assert [%{"id" => "428897538", "type" => "private"}] = ChatLink.capturable_chats(updates)
    end

    test "captures a group chat, so a bot added to a group can be linked" do
      # The reason this module exists: the old private-only filter silently
      # dropped group updates, leaving no way at all to link a group.
      updates = [
        message_update(1, %{"id" => -1_001_234_567_890, "type" => "supergroup", "title" => "Shop"})
      ]

      assert [%{"id" => "-1001234567890", "type" => "supergroup", "title" => "Shop"}] =
               ChatLink.capturable_chats(updates)
    end

    test "keeps the chat title so the UI can name a linked chat instead of showing a bare id" do
      updates = [message_update(1, %{"id" => -400, "type" => "group", "title" => "Orders"})]

      assert [%{"title" => "Orders"}] = ChatLink.capturable_chats(updates)
    end

    test "ignores updates that carry no message chat" do
      assert ChatLink.capturable_chats([%{"update_id" => 1, "edited_message" => %{}}]) == []
    end

    test "de-duplicates a chat that sent several messages" do
      chat = %{"id" => 7, "type" => "private"}

      assert [%{"id" => "7"}] =
               ChatLink.capturable_chats([message_update(1, chat), message_update(2, chat)])
    end
  end

  describe "merge/3 in single mode" do
    test "locks the most recent private chat when nothing is linked yet" do
      chats = [
        %{"id" => "111", "type" => "private"},
        %{"id" => "222", "type" => "private"}
      ]

      assert {["222"], ["222"]} = ChatLink.merge("single", [], chats)
    end

    test "keeps the already-locked private chat instead of switching to a newer one" do
      chats = [%{"id" => "999", "type" => "private"}]

      assert {["111"], []} = ChatLink.merge("single", ["111"], chats)
    end

    test "still links a group while the private chat stays locked" do
      # A group is linked by someone who can post in it and deliberately ran the
      # command there — it is never the "stranger messaged the bot" case that
      # single mode locks against, so it must not be blocked by the lock.
      chats = [%{"id" => "-1001234567890", "type" => "supergroup", "title" => "Shop"}]

      assert {["111", "-1001234567890"], ["-1001234567890"]} =
               ChatLink.merge("single", ["111"], chats)
    end
  end

  describe "kind/1" do
    test "reads a group from the negative sign Telegram gives group ids" do
      assert :group = ChatLink.kind("-1001234567890")
    end

    test "reads a channel from an @handle" do
      assert :channel = ChatLink.kind("@decor3d_orders")
    end

    test "reads a private chat from a plain positive id" do
      assert :private = ChatLink.kind("428897538")
    end
  end

  describe "merge/3 and chats that are neither private nor a group" do
    test "a hand-linked channel does not count as the locked private chat" do
      # The lock asks "is a private chat already linked". Answering it with
      # "does this id start with a minus" made an @handle look private, so a
      # channel linked by hand silently consumed the single slot and the
      # owner's own chat could never be captured.
      chats = [%{"id" => "428897538", "type" => "private"}]

      assert {["@myannounce", "428897538"], ["428897538"]} =
               ChatLink.merge("single", ["@myannounce"], chats)
    end
  end

  describe "capture/4" do
    test "records metadata only for chats that were actually linked" do
      # In single mode a stranger's chat is refused by the lock; remembering
      # who they are anyway turns chat_meta into a log of everyone who ever
      # messaged the bot.
      chats = [
        %{"id" => "999", "type" => "private", "title" => nil},
        %{"id" => "-500", "type" => "group", "title" => "Shop"}
      ]

      %{ids: ids, added: added, meta: meta} = ChatLink.capture("single", ["111"], %{}, chats)

      assert ids == ["111", "-500"]
      assert added == ["-500"]
      assert Map.keys(meta) == ["-500"]
    end

    test "keeps metadata already known for a still-linked chat" do
      known = %{"111" => %{"type" => "private", "title" => nil}}

      %{meta: meta} = ChatLink.capture("single", ["111"], known, [])

      assert Map.has_key?(meta, "111")
    end

    test "drops metadata for a chat that is no longer linked" do
      known = %{"gone" => %{"type" => "group", "title" => "Old"}}

      %{meta: meta} = ChatLink.capture("single", ["111"], known, [])

      refute Map.has_key?(meta, "gone")
    end
  end

  describe "prune_meta/2" do
    test "keeps only metadata for ids still linked" do
      meta = %{"a" => %{"type" => "private"}, "b" => %{"type" => "group"}}

      assert %{"b" => %{"type" => "group"}} == ChatLink.prune_meta(meta, ["b"])
    end
  end

  describe "merge/3 in multi mode" do
    test "unions every captured chat with what is already linked" do
      chats = [%{"id" => "222", "type" => "private"}, %{"id" => "-300", "type" => "group"}]

      assert {["111", "222", "-300"], ["222", "-300"]} = ChatLink.merge("multi", ["111"], chats)
    end

    test "adds nothing when every captured chat is already linked" do
      chats = [%{"id" => "111", "type" => "private"}]

      assert {["111"], []} = ChatLink.merge("multi", ["111"], chats)
    end
  end

  describe "normalize_chat_id/1" do
    test "accepts a numeric private chat id" do
      assert {:ok, "428897538"} = ChatLink.normalize_chat_id(" 428897538 ")
    end

    test "accepts a negative group id" do
      assert {:ok, "-1001234567890"} = ChatLink.normalize_chat_id("-1001234567890")
    end

    test "accepts an @channelusername" do
      assert {:ok, "@decor3d_orders"} = ChatLink.normalize_chat_id("@decor3d_orders")
    end

    test "rejects anything that is not a chat id" do
      for junk <- ["", "   ", "not an id", "12 34", "@", "-", "@with spaces"] do
        assert :error = ChatLink.normalize_chat_id(junk),
               "expected #{inspect(junk)} to be rejected"
      end
    end
  end
end
