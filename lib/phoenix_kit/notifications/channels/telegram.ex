defmodule PhoenixKit.Notifications.Channels.Telegram do
  @moduledoc """
  Telegram notification channel — delivers a user's notifications to their
  personal Telegram bot connection(s).

  There's nothing to configure on the notifications page: the channel
  **auto-discovers** the recipient's Telegram integration connections and sends
  to the chat(s) captured on them (during Test on the integration form). Each
  connection carries a `mode`:

    * `"single"` — auto-capture locks one private chat (the owner's), so a
      stranger who messages the bot right after them is not picked up.
    * `"multi"` — every chat that has started the bot → a broadcast.

  The mode governs auto-capture only: the owner can also link a chat by id
  (a group, a channel), so `chat_ids` is not capped by it. The channel sends
  to every id on the list and does not care which kind each one is.

  `configured?/2` is true once the recipient has a connection with at least
  one linked chat. The bot token is resolved owner-scoped to the recipient at
  send time — this module never handles it.

  The `config` arg (the `notification_channel:telegram` blob) carries only
  routing/cadence for this channel; connection + chat live on the integration.
  """

  @behaviour PhoenixKit.Notifications.Channel

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram, as: Client

  @impl true
  def key, do: "telegram"

  @impl true
  def label, do: gettext("Telegram")

  @impl true
  def icon, do: "hero-paper-airplane"

  @impl true
  def configured?(user_uuid, _config), do: linked_targets(user_uuid) != []

  @impl true
  def deliver(envelope, _config) do
    deliver_to(linked_targets(envelope.recipient_uuid), envelope)
  end

  @impl true
  def validate_config(config) when is_map(config), do: {:ok, config}

  # --- Discovery ------------------------------------------------------------

  # `{connection_uuid, chat_id}` pairs for every chat captured on the user's
  # Telegram connections. Single-mode connections contribute one; multi many.
  defp linked_targets(user_uuid) when is_binary(user_uuid) do
    "telegram"
    |> Integrations.list_connections(owner: {:user, user_uuid})
    |> Enum.flat_map(fn %{uuid: uuid, data: data} ->
      Enum.map(chat_ids_of(data), &{uuid, &1})
    end)
  rescue
    _ -> []
  end

  defp linked_targets(_), do: []

  defp chat_ids_of(data) do
    case data["chat_ids"] do
      list when is_list(list) -> list |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))
      _ -> []
    end
  end

  # --- Delivery -------------------------------------------------------------

  defp deliver_to([], _envelope), do: {:error, {:permanent, :not_configured}}

  # A single target (single mode / one bot, one chat): propagate the error so a
  # blocked chat soft-disables the channel.
  defp deliver_to([{uuid, chat_id}], envelope) do
    case send(uuid, chat_id, envelope) do
      {:ok, _} -> :ok
      {:error, reason} -> classify(reason)
    end
  end

  # Several targets (multi mode / broadcast): best-effort — one blocked
  # subscriber shouldn't disable the whole channel. Retry only if something was
  # transiently unreachable (may re-send to already-delivered chats — Telegram
  # has no idempotency key, so delivery is at-least-once).
  defp deliver_to(targets, envelope) do
    results = Enum.map(targets, fn {uuid, chat_id} -> send(uuid, chat_id, envelope) end)

    cond do
      Enum.all?(results, &match?({:ok, _}, &1)) ->
        :ok

      Enum.any?(results, &transient?/1) ->
        {:error, {:transient, :partial}}

      true ->
        # Every send failed permanently (bot blocked/kicked everywhere, bad
        # token, …). We still report :ok so one dead subscriber can't disable a
        # working broadcast — but a wholly-failed send must not look like a
        # success in the logs, or a mis-set token is invisible forever.
        Logger.warning(
          "[Notifications.Telegram] broadcast to #{length(targets)} chat(s) failed permanently: " <>
            inspect(Enum.reject(results, &match?({:ok, _}, &1)))
        )

        :ok
    end
  end

  defp send(uuid, chat_id, envelope) do
    Client.send_message(uuid, chat_id, body(envelope), owner: {:user, envelope.recipient_uuid})
  end

  defp transient?({:error, reason}),
    do:
      match?({:error, {:transient, _}}, classify(reason)) or
        match?({:error, {:transient, _}, _}, classify(reason))

  defp transient?(_), do: false

  # Plain text (no parse_mode) so notification content can't break Telegram
  # markup. The deep-link goes on its own line.
  defp body(%{text: text, url: url}) when is_binary(url) and url != "", do: "#{text}\n\n#{url}"
  defp body(%{text: text}), do: text

  # Map the send client's error into the permanent/transient taxonomy.
  defp classify(:unreachable), do: {:error, {:transient, :unreachable}}

  defp classify(reason) when reason in [:not_configured, :deleted],
    do: {:error, {:permanent, reason}}

  defp classify(desc) when is_binary(desc) do
    down = String.downcase(desc)

    cond do
      String.contains?(down, "too many requests") ->
        {:error, {:transient, desc}, retry_after_ms(desc)}

      String.contains?(down, [
        "blocked",
        "deactivated",
        "chat not found",
        "bot can't initiate",
        "bot can’t initiate",
        "kicked",
        "forbidden",
        "have no rights",
        "not enough rights"
      ]) ->
        {:error, {:permanent, desc}}

      String.contains?(down, [
        "internal server error",
        "bad gateway",
        "gateway",
        # any 5xx (the client formats a bodyless server error as "Telegram error 5xx")
        "telegram error 5",
        "502",
        "503",
        "504"
      ]) ->
        {:error, {:transient, desc}}

      true ->
        {:error, {:permanent, desc}}
    end
  end

  defp classify(other), do: {:error, {:permanent, other}}

  defp retry_after_ms(desc) do
    case Regex.run(~r/retry after (\d+)/i, desc) do
      [_, seconds] -> String.to_integer(seconds) * 1000
      _ -> 1000
    end
  end
end
