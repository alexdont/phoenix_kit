defmodule PhoenixKit.Users.SessionsDeviceTest do
  @moduledoc """
  Integration tests for the self-service Active Sessions surface:
  device-enriched listing, the current-session flag, and the user-scoped
  revoke functions (which must never let one user revoke another's session).
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.SessionFingerprint

  defp user_fixture(email) do
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    user
  end

  defp session_token(user, ip, ua_hash) do
    fp = %SessionFingerprint{ip_address: ip, user_agent_hash: ua_hash}
    Auth.generate_user_session_token(user, fingerprint: fp)
  end

  defp known_device(user, ip, ua_hash, extra) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %KnownDevice{}
    |> KnownDevice.changeset(
      Map.merge(
        %{
          user_uuid: user.uuid,
          ip_address: ip,
          user_agent_hash: ua_hash,
          first_seen_at: now,
          last_seen_at: now
        },
        extra
      )
    )
    |> Repo.insert!()
  end

  describe "list_user_device_sessions/2" do
    test "enriches from known devices and flags the current session" do
      user = user_fixture("qr-sessions-list@example.com")
      ua = String.duplicate("a", 64)
      current = session_token(user, "203.0.113.1", ua)
      _other = session_token(user, "203.0.113.2", String.duplicate("b", 64))

      known_device(user, "203.0.113.1", ua, %{
        browser: "Chrome",
        os: "macOS",
        location: "Berlin, DE"
      })

      sessions = Sessions.list_user_device_sessions(user, current)
      assert length(sessions) == 2

      cur = Enum.find(sessions, & &1.is_current)
      assert cur.browser == "Chrome"
      assert cur.os == "macOS"
      assert cur.location == "Berlin, DE"
      assert cur.ip_address == "203.0.113.1"

      # A session with no matching known-device row degrades gracefully.
      other = Enum.find(sessions, &(not &1.is_current))
      assert other.browser == nil
      assert other.location == nil
    end

    test "enriches a session whose IPv6 address is in the known device's /64" do
      user = user_fixture("qr-sessions-v6net@example.com")
      ua = String.duplicate("a", 64)
      current = session_token(user, "2001:db8:1:1::2", ua)
      _other = session_token(user, "2001:db8:1:2::1", ua)

      known_device(user, "2001:db8:1:1::1", ua, %{
        browser: "Firefox",
        os: "Linux",
        location: "Lisbon, PT"
      })

      sessions = Sessions.list_user_device_sessions(user, current)
      cur = Enum.find(sessions, & &1.is_current)
      assert cur.location == "Lisbon, PT"
      assert cur.ip_address == "2001:db8:1:1::2"

      other = Enum.find(sessions, &(not &1.is_current))
      assert other.location == nil
      assert other.ip_address == "2001:db8:1:2::1"
    end

    test "device name comes from the token itself, no known-device row needed" do
      user = user_fixture("qr-sessions-tokendev@example.com")

      fp = %SessionFingerprint{
        ip_address: "203.0.113.20",
        user_agent_hash: String.duplicate("1", 64)
      }

      token =
        Auth.generate_user_session_token(user, fingerprint: fp, browser: "Safari", os: "iOS")

      [s] = Sessions.list_user_device_sessions(user, token)
      assert s.browser == "Safari"
      assert s.os == "iOS"
      assert s.is_current
    end

    test "no session is current when the token is unknown" do
      user = user_fixture("qr-sessions-nocurrent@example.com")
      _t = session_token(user, "203.0.113.3", String.duplicate("c", 64))

      sessions = Sessions.list_user_device_sessions(user, "not-a-real-token")
      assert Enum.all?(sessions, &(not &1.is_current))
    end
  end

  describe "revoke_user_session/2" do
    test "revokes the owner's session but not another user's" do
      user = user_fixture("qr-sessions-owner@example.com")
      intruder = user_fixture("qr-sessions-intruder@example.com")
      token = session_token(user, "203.0.113.5", String.duplicate("d", 64))

      [%{token_uuid: uuid}] = Sessions.list_user_device_sessions(user, token)

      # Cross-user revoke is refused even with the correct token uuid.
      assert {:error, :not_found} = Sessions.revoke_user_session(intruder, uuid)
      assert length(Sessions.list_user_device_sessions(user, token)) == 1

      # The owner can revoke it.
      assert :ok = Sessions.revoke_user_session(user, uuid)
      assert Sessions.list_user_device_sessions(user, token) == []
    end
  end

  describe "revoke_other_user_sessions/2" do
    test "keeps the current session and revokes the rest" do
      user = user_fixture("qr-sessions-others@example.com")
      current = session_token(user, "203.0.113.7", String.duplicate("e", 64))
      _s2 = session_token(user, "203.0.113.8", String.duplicate("f", 64))
      _s3 = session_token(user, "203.0.113.9", String.duplicate("0", 64))

      assert length(Sessions.list_user_device_sessions(user, current)) == 3

      assert Sessions.revoke_other_user_sessions(user, current) == 2

      remaining = Sessions.list_user_device_sessions(user, current)
      assert [%{is_current: true}] = remaining
    end

    test "with a nil token revokes every session" do
      user = user_fixture("qr-sessions-nil@example.com")
      _s1 = session_token(user, "203.0.113.10", String.duplicate("a", 64))
      _s2 = session_token(user, "203.0.113.11", String.duplicate("b", 64))

      assert Sessions.revoke_other_user_sessions(user, nil) == 2
      assert Sessions.list_user_device_sessions(user, nil) == []
    end
  end

  describe "get_session_stats/0" do
    test "unique_users counts PEOPLE, not session rows" do
      # The bug this pins, reported from a live install: 29 "unique users"
      # against 2 registered accounts, because the count was written as
      # `Repo.aggregate(query, :count, :user_uuid, distinct: true)`. That last
      # argument is REPO options, never query modifiers, so `distinct: true`
      # was accepted and silently ignored — and the panel reported one "unique
      # user" per session row.
      user = user_fixture("stats-unique-one@example.com")

      for n <- 1..3 do
        session_token(user, "203.0.113.#{n}", String.duplicate("#{n}", 64))
      end

      stats = Sessions.get_session_stats()

      assert stats.total_active >= 3
      # One person, three sessions. The two numbers must be able to differ —
      # equality here is what the defect looked like.
      assert stats.unique_users < stats.total_active
    end

    test "a second person raises unique_users by exactly one" do
      before = Sessions.get_session_stats()

      user = user_fixture("stats-unique-two@example.com")
      session_token(user, "203.0.113.90", String.duplicate("9", 64))
      session_token(user, "203.0.113.91", String.duplicate("8", 64))

      after_stats = Sessions.get_session_stats()

      assert after_stats.unique_users == before.unique_users + 1
      assert after_stats.total_active == before.total_active + 2
    end

    test "breaks active sessions down by OS and browser" do
      user = user_fixture("qr-sessions-stats@example.com")

      fp1 = %SessionFingerprint{
        ip_address: "203.0.113.30",
        user_agent_hash: String.duplicate("2", 64)
      }

      fp2 = %SessionFingerprint{
        ip_address: "203.0.113.31",
        user_agent_hash: String.duplicate("3", 64)
      }

      Auth.generate_user_session_token(user, fingerprint: fp1, browser: "Safari", os: "iOS")
      Auth.generate_user_session_token(user, fingerprint: fp2, browser: "Safari", os: "iOS")

      stats = Sessions.get_session_stats()
      assert {"iOS", 2} in stats.by_os
      assert {"Safari", 2} in stats.by_browser
    end

    test "counts sessions without a device name under \"Unknown\"" do
      user = user_fixture("qr-sessions-stats-unknown@example.com")

      fp = %SessionFingerprint{
        ip_address: "203.0.113.32",
        user_agent_hash: String.duplicate("4", 64)
      }

      Auth.generate_user_session_token(user, fingerprint: fp)

      stats = Sessions.get_session_stats()
      assert {"Unknown", 1} in stats.by_os
    end
  end

  # Deleting the row ends the session at the next request and does nothing to a
  # socket that is already connected: it keeps its authenticated assigns and
  # goes on serving events until it re-mounts. "Sign out this device" that
  # leaves the device working is the failure these cover.
  describe "revocation disconnects live sockets" do
    defp watch_socket(token) do
      PhoenixKitWeb.Endpoint.subscribe(Sessions.live_socket_id(token))
      token
    end

    # The listing exposes only the 4-byte preview the UI shows, never the raw
    # token — match on that to find the row for a token the test holds.
    defp token_uuid_for(user, token) do
      preview = Base.encode16(binary_part(token, 0, 4), case: :lower)

      user
      |> Sessions.list_user_sessions()
      |> Enum.find(&(&1.token_preview == preview))
      |> Map.fetch!(:token_uuid)
    end

    test "revoking one session disconnects that session only" do
      user = user_fixture("revoke-disconnect-one@example.com")
      revoked = watch_socket(Auth.generate_user_session_token(user))
      kept = watch_socket(Auth.generate_user_session_token(user))

      assert :ok = Sessions.revoke_user_session(user, token_uuid_for(user, revoked))

      revoked_topic = Sessions.live_socket_id(revoked)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^revoked_topic, event: "disconnect"}

      kept_topic = Sessions.live_socket_id(kept)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^kept_topic}, 50
    end

    test "disconnect_tokens_later/2 closes the socket after the delay, and only that one" do
      # The suite does not run the application supervisor; without this the
      # helper falls back to an immediate disconnect and the delay is untested.
      start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})
      user = user_fixture("revoke-disconnect-later@example.com")
      old = watch_socket(Auth.generate_user_session_token(user))
      fresh = watch_socket(Auth.generate_user_session_token(user))

      assert :ok = Sessions.disconnect_tokens_later([old], 100)

      old_topic = Sessions.live_socket_id(old)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^old_topic}, 20
      assert_receive %Phoenix.Socket.Broadcast{topic: ^old_topic, event: "disconnect"}, 1_000

      fresh_topic = Sessions.live_socket_id(fresh)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^fresh_topic}, 50
    end

    test "signing out other devices spares the one asking" do
      user = user_fixture("revoke-disconnect-others@example.com")
      current = watch_socket(Auth.generate_user_session_token(user))
      other = watch_socket(Auth.generate_user_session_token(user))

      assert 1 = Sessions.revoke_other_user_sessions(user, current)

      other_topic = Sessions.live_socket_id(other)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}

      current_topic = Sessions.live_socket_id(current)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^current_topic}, 50
    end

    test "deactivating a user disconnects every session they have open" do
      user = user_fixture("revoke-disconnect-deactivated@example.com")
      token = watch_socket(Auth.generate_user_session_token(user))

      assert {:ok, _user} = Auth.update_user_status(user, %{"is_active" => false})

      topic = Sessions.live_socket_id(token)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "an admin password reset disconnects the account's open sessions" do
      user = user_fixture("revoke-disconnect-password@example.com")
      token = watch_socket(Auth.generate_user_session_token(user))

      assert {:ok, _user} =
               Auth.admin_update_user_password(user, %{
                 password: "AnotherValidPassword123!",
                 password_confirmation: "AnotherValidPassword123!"
               })

      topic = Sessions.live_socket_id(token)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "a self-service password change disconnects other devices but not the one submitting" do
      user = user_fixture("revoke-disconnect-self-pw@example.com")
      current = watch_socket(Auth.generate_user_session_token(user))
      other = watch_socket(Auth.generate_user_session_token(user))

      # The settings form still needs this socket: `phx-trigger-action` POSTs
      # the re-login, and a disconnect here is a page reload onto a deleted
      # remember-me token — a sign-out the user never asked for.
      assert {:ok, _user} =
               Auth.update_user_password(
                 user,
                 "ValidPassword123!",
                 %{
                   password: "AnotherValidPassword123!",
                   password_confirmation: "AnotherValidPassword123!"
                 },
                 except_token: current
               )

      other_topic = Sessions.live_socket_id(other)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}

      current_topic = Sessions.live_socket_id(current)
      refute_receive %Phoenix.Socket.Broadcast{topic: ^current_topic}, 50
    end

    test "a self-service password change without except_token disconnects every session" do
      user = user_fixture("revoke-disconnect-self-pw-all@example.com")
      token = watch_socket(Auth.generate_user_session_token(user))

      assert {:ok, _user} =
               Auth.update_user_password(user, "ValidPassword123!", %{
                 password: "AnotherValidPassword123!",
                 password_confirmation: "AnotherValidPassword123!"
               })

      topic = Sessions.live_socket_id(token)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end
  end
end
