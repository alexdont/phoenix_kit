defmodule PhoenixKit.Settings.Events do
  @moduledoc """
  Live notifications for settings changes.

  Subscribe with `PhoenixKit.Settings.subscribe/0` (or `subscribe_to_settings/0`
  here) and a process receives, for every committed write through
  `PhoenixKit.Settings` that changed a value:

      {:setting_changed, key, value}   # the committed value
      {:setting_changed, key, :redacted}   # a secret changed; value withheld
      {:setting_deleted, key}

  `broadcast_content_language_changed/1` sends
  `{:content_language_changed, language}` on the same topic for a caller that
  announces a content-language switch; nothing in core sends it today, so a
  subscriber only sees it if its own code does.

  ## Guarantees

    * **Only real changes.** A write that stores the value already there sends
      nothing, and a write that rolled back sends nothing.
    * **The value travels with the message.** It is the committed value, and
      the local settings cache has already dropped the old one before the
      message goes out, so a subscriber may use the value directly or read it
      again — both are current on this node.
    * **Secrets never travel.** A row that holds credential material carries
      `:redacted` instead of a value: PubSub delivers to any process on the
      node, and a subscriber that needs the secret reads it through the access
      it already has. What counts as a secret is `secret_key?/2` — integration
      connection rows included, whatever their key.
    * **Order between writers is not guaranteed.** Two processes writing one
      key can have their messages delivered in either order. When that matters,
      treat the message as "this key changed" and read the setting again rather
      than keeping the last payload received.

  ## Limits

    * **One node's cache.** The writing node drops its cached value before
      notifying. Nothing drops another node's copy: the message reaches every
      node, but a cached read there keeps returning the old value until the
      settings cache's TTL (five minutes) expires it. On a cluster, use the
      value in the message rather than re-reading — a secret setting arrives
      as `:redacted`, so read it through `PhoenixKit.Settings.Queries` (the
      database) if you need it at once.
    * **Inside your own transaction.** A settings write called inside a
      transaction your code opened notifies when the settings call returns,
      not when your transaction commits (Ecto has no after-commit hook). If
      your transaction then rolls back, subscribers heard of a change that did
      not happen. The same goes for `{:setting_deleted, key}` from a delete.
      The activity feed's `setting.changed` entries share this.
    * **A cache that does not answer.** The old value is dropped with a
      five-second call. A cache that misses that deadline (or is not running)
      is logged and the message still goes out; a slow cache drops the value
      when it gets to the request, so a re-read in between can return the old
      one. A dead cache is not read at all, so nothing stale is served.
    * **Best effort, not durable.** The message is sent once, after the
      commit. A notification that fails (no PubSub in a Mix task, say) is
      logged and the write stands; there is no retry or outbox.
  """

  alias PhoenixKit.PubSub.Manager

  @topic_settings "phoenix_kit:settings"

  # Substrings that mark a key as credential material even when no list names
  # it. Integration rows (`integration:*`) are encrypted credentials by
  # construction, and modules write their own secrets through this same
  # table. A false positive only withholds a value the subscriber can read
  # anyway; a false negative broadcasts a secret, so this errs wide.
  @secret_fragments ~w(secret password passwd token private_key api_key apikey credential webhook)

  @doc "Subscribe the calling process to settings change events."
  def subscribe_to_settings, do: Manager.subscribe(@topic_settings)

  @doc "Broadcast that the content language setting changed."
  def broadcast_content_language_changed(new_language) do
    Manager.broadcast(@topic_settings, {:content_language_changed, new_language})
  end

  @doc """
  Broadcast that `key` now holds `value`.

  The value is withheld (`:redacted`) when `secret_key?/2` says the row holds
  credential material, whatever the caller passed. Pass the row's `module`
  when it is known: integration rows have uuid keys and are recognised only by
  it.
  """
  def broadcast_setting_changed(key, value, module \\ nil) do
    Manager.broadcast(
      @topic_settings,
      {:setting_changed, key, public_value(key, module, value)}
    )
  end

  @doc "Broadcast that `key` was deleted."
  def broadcast_setting_deleted(key) do
    Manager.broadcast(@topic_settings, {:setting_deleted, key})
  end

  @doc """
  Whether a row holds credential material that must never be broadcast.

  True for everything `PhoenixKit.Settings.secret_setting?/2` withholds (the
  restricted keys and every integration row, recognised by `module`), and —
  wider on purpose, because withholding only costs a subscriber a re-read —
  for any key whose name marks it as a secret.
  """
  @spec secret_key?(String.t(), String.t() | nil) :: boolean()
  def secret_key?(key, module \\ nil) when is_binary(key) do
    PhoenixKit.Settings.secret_setting?(key, module) or
      String.contains?(String.downcase(key), @secret_fragments)
  end

  defp public_value(key, module, value) do
    if secret_key?(key, module), do: :redacted, else: value
  end
end
