defmodule PhoenixKit.Integrations.Telegram.ChatLink do
  @moduledoc """
  Pure chat-linking rules for the Telegram integration: which chats a
  `getUpdates` peek may link, how a capture merges into what is already
  linked, and what counts as a hand-entered chat id.

  Split out of the LiveView because this is where the surprising parts live
  (a locked private chat that must still admit a group, ids whose sign
  carries meaning) and because a form event is a poor place to prove them.

  ## Chat kinds

  Telegram numbers private chats positively and group/supergroup chats
  negatively — a documented invariant this module leans on, since a stored
  `chat_ids` entry is just a string with no type alongside it.

  ## Privacy mode

  A bot added to a group only receives messages addressed to it (a `/`
  command, an @mention, a reply, or a service message) unless it is a group
  admin. So a group reaches `capturable_chats/1` when someone runs
  `/start@yourbot` **in that group** — plain chatter never will.
  """

  @group_types ~w(group supergroup)
  @linkable_types ["private" | @group_types]

  @doc """
  Chats that may be linked from a `getUpdates` result, oldest first, one
  entry per chat.

  Keeps the chat's `type` and `title` so a caller can name a linked chat
  rather than show a bare id.
  """
  @spec capturable_chats([map()]) :: [map()]
  def capturable_chats(updates) when is_list(updates) do
    updates
    |> Enum.flat_map(fn update ->
      chat = get_in(update, ["message", "chat"]) || %{}

      if chat["type"] in @linkable_types and chat["id"] do
        [%{"id" => to_string(chat["id"]), "type" => chat["type"], "title" => chat["title"]}]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1["id"])
  end

  @doc """
  Folds captured chats into the already-linked ids, returning
  `{linked_ids, newly_added_ids}`.

  `"single"` locks ONE private chat: the most recent one, and only while no
  private chat is linked yet — a stranger who messaged the bot right after
  the owner cannot displace it. A **group is never subject to that lock**:
  it is linked by someone who can post in it and deliberately ran the
  command there, which is not the case the lock defends against.

  `"multi"` unions everything captured. The empty `newly_added_ids` is what
  lets a caller tell "nothing new was found" from "linked a chat" — the old
  code could not, and reported success either way.

  Both modes govern AUTO-CAPTURE only. Linking a chat by id is a deliberate
  act by the connection's owner, so it is not capped here: "single" means
  "capture cannot quietly add a second private chat", not "this connection
  can only ever reach one chat".
  """
  @spec merge(String.t(), [String.t()], [map()]) :: {[String.t()], [String.t()]}
  def merge(mode, existing, chats) when is_list(existing) and is_list(chats) do
    {groups, privates} = Enum.split_with(chats, &group?/1)

    candidates =
      case mode do
        "multi" -> ids(privates) ++ ids(groups)
        "single" -> lockable_private(existing, privates) ++ ids(groups)
        _ -> ids(groups)
      end

    added = candidates |> Enum.uniq() |> Enum.reject(&(&1 in existing))

    {existing ++ added, added}
  end

  @doc """
  Normalizes a hand-entered chat id — a numeric id (negative for groups) or
  an `@channelusername`, both of which `sendMessage` accepts.

  Hand entry exists because capture only reaches chats whose update is still
  in Telegram's ~24h queue; an id you already know should not need that
  window.
  """
  @spec normalize_chat_id(String.t()) :: {:ok, String.t()} | :error
  def normalize_chat_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      Regex.match?(~r/^-?\d+$/, trimmed) -> {:ok, trimmed}
      Regex.match?(~r/^@[A-Za-z0-9_]{3,}$/, trimmed) -> {:ok, trimmed}
      true -> :error
    end
  end

  def normalize_chat_id(_), do: :error

  @doc """
  Folds a `getUpdates` peek into everything the connection should store:
  the linked ids, which of them are new, and the metadata for those ids.

  Metadata is kept for LINKED chats only, and pruned to them. Recording a
  chat the lock just refused would turn the connection's data into a log of
  everyone who has ever messaged the bot.
  """
  @spec capture(String.t(), [String.t()], map(), [map()]) :: %{
          ids: [String.t()],
          added: [String.t()],
          meta: map()
        }
  def capture(mode, existing, existing_meta, chats) do
    {ids, added} = merge(mode, existing, chats)

    meta =
      chats
      |> Enum.reduce(existing_meta || %{}, fn chat, acc ->
        Map.put(acc, chat["id"], %{"type" => chat["type"], "title" => chat["title"]})
      end)
      |> prune_meta(ids)

    %{ids: ids, added: added, meta: meta}
  end

  @doc "Metadata for the given ids only — everything else is dropped."
  @spec prune_meta(map(), [String.t()]) :: map()
  def prune_meta(meta, ids) when is_map(meta) and is_list(ids), do: Map.take(meta, ids)
  def prune_meta(_meta, ids) when is_list(ids), do: %{}

  @doc """
  What a stored id denotes. A stored `chat_ids` entry is a bare string, so
  kind is read back from its shape: Telegram signs group ids negative, and a
  channel is linked by its `@handle`.
  """
  @spec kind(String.t()) :: :group | :channel | :private
  def kind("@" <> _), do: :channel
  def kind("-" <> _), do: :group
  def kind(_), do: :private

  @doc "Whether a stored id denotes a group/supergroup."
  @spec group_id?(String.t()) :: boolean()
  def group_id?(id) when is_binary(id), do: kind(id) == :group
  def group_id?(_), do: false

  defp group?(chat), do: chat["type"] in @group_types

  defp ids(chats), do: Enum.map(chats, & &1["id"])

  # The lock is per-KIND: a linked group — or a hand-linked channel — must not
  # block linking the private chat the operator still owes themselves. Asking
  # "does this id start with a minus" got that wrong for an @handle, which
  # silently consumed the single slot.
  defp lockable_private(existing, privates) do
    if Enum.any?(existing, &(kind(&1) == :private)) do
      []
    else
      privates |> ids() |> Enum.take(-1)
    end
  end
end
