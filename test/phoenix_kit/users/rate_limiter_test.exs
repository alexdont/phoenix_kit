defmodule PhoenixKit.Users.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.RateLimiter.Backend

  # Start the Hammer ETS backend before all tests (may already be running from test_helper)
  setup_all do
    case :ets.whereis(Backend) do
      :undefined ->
        {:ok, pid} = Backend.start_link([])
        {:ok, %{backend_pid: pid}}

      _ref ->
        {:ok, %{backend_pid: nil}}
    end
  end

  # Generate unique email for each test to avoid cross-test pollution
  setup do
    unique_id = :erlang.unique_integer([:positive])
    {:ok, unique_id: unique_id}
  end

  describe "check_login_rate_limit/2" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "user_#{id}@example.com"

      # First 5 attempts should succeed
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "blocked_#{id}@example.com"

      # Exhaust the rate limit (default: 5 attempts)
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email)
      end

      # 6th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "user1_#{id}@example.com"
      email2 = "user2_#{id}@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..5 do
        assert :ok = RateLimiter.check_login_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_login_rate_limit(email2)
    end

    test "includes IP-based rate limiting when IP provided", %{unique_id: id} do
      email = "user_#{id}@example.com"
      ip = "192.168.1.#{rem(id, 255)}"

      # Should succeed with IP
      assert :ok = RateLimiter.check_login_rate_limit(email, ip)
    end

    test "normalizes email addresses", %{unique_id: id} do
      email_lower = "norm_#{id}@example.com"
      email_upper = "NORM_#{id}@EXAMPLE.COM"
      email_mixed = "NoRm_#{id}@ExAmPlE.cOm"

      # All variations should count toward same limit
      assert :ok = RateLimiter.check_login_rate_limit(email_lower)
      assert :ok = RateLimiter.check_login_rate_limit(email_upper)
      assert :ok = RateLimiter.check_login_rate_limit(email_mixed)

      # Continue to exhaust limit with different case variations
      assert :ok = RateLimiter.check_login_rate_limit(email_lower)
      assert :ok = RateLimiter.check_login_rate_limit(email_upper)

      # Should be blocked now (5 attempts reached)
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_login_rate_limit(email_mixed)
    end
  end

  describe "check_magic_link_rate_limit/1" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "magic_#{id}@example.com"

      # First 3 attempts should succeed (default magic link limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "magic_blocked_#{id}@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "magic1_#{id}@example.com"
      email2 = "magic2_#{id}@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_magic_link_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_magic_link_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_magic_link_rate_limit(email2)
    end
  end

  describe "check_password_reset_rate_limit/1" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "pwreset_#{id}@example.com"

      # First 3 attempts should succeed (default password reset limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "pwreset_blocked_#{id}@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email)
    end

    test "rate limits are per-email", %{unique_id: id} do
      email1 = "pwreset1_#{id}@example.com"
      email2 = "pwreset2_#{id}@example.com"

      # Exhaust rate limit for email1
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email1)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email1)

      # email2 should still be allowed
      assert :ok = RateLimiter.check_password_reset_rate_limit(email2)
    end
  end

  describe "check_registration_rate_limit/2" do
    test "allows requests within rate limit", %{unique_id: id} do
      email = "newuser_#{id}@example.com"

      # First 3 attempts should succeed (default registration limit)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_registration_rate_limit(email)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      email = "spammer_#{id}@example.com"

      # Exhaust the rate limit (default: 3 attempts)
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_registration_rate_limit(email)
      end

      # 4th attempt should be blocked
      assert {:error, :rate_limit_exceeded} = RateLimiter.check_registration_rate_limit(email)
    end

    test "includes IP-based rate limiting when IP provided", %{unique_id: id} do
      email = "reg_#{id}@example.com"
      ip = "10.0.#{rem(id, 255)}.100"

      # Should succeed with IP
      assert :ok = RateLimiter.check_registration_rate_limit(email, ip)
    end

    test "IP-based rate limiting is independent of email", %{unique_id: id} do
      ip = "10.1.#{rem(id, 255)}.200"

      # Different emails from same IP should count toward IP limit
      # Default IP limit is 10, so we test a few
      for i <- 1..5 do
        email = "regip_#{id}_#{i}@example.com"
        assert :ok = RateLimiter.check_registration_rate_limit(email, ip)
      end
    end
  end

  describe "check_qr_login_rate_limit/1" do
    test "allows requests within rate limit", %{unique_id: id} do
      ip = "172.16.0.#{rem(id, 255)}"

      # First 10 attempts should succeed (default QR login limit)
      for _ <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit(ip)
      end
    end

    test "blocks requests after exceeding rate limit", %{unique_id: id} do
      ip = "172.16.1.#{rem(id, 255)}"

      for _ <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit(ip)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_qr_login_rate_limit(ip)
    end

    test "rate limits are per-IP", %{unique_id: id} do
      ip1 = "172.16.2.#{rem(id, 255)}"
      ip2 = "172.16.3.#{rem(id, 255)}"

      for _ <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit(ip1)
      end

      assert {:error, :rate_limit_exceeded} = RateLimiter.check_qr_login_rate_limit(ip1)
      assert :ok = RateLimiter.check_qr_login_rate_limit(ip2)
    end

    # Every address in a /64 belongs to the same client, who can pick a
    # fresh one per request — the bucket has to be the /64.
    test "IPv6 addresses in the same /64 share one bucket", %{unique_id: id} do
      net = Integer.to_string(rem(id, 0xFFFF), 16)

      for n <- 1..10 do
        assert :ok = RateLimiter.check_qr_login_rate_limit("2001:db8:#{net}:1::#{n}")
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_qr_login_rate_limit("2001:db8:#{net}:1:dead:beef:0:99")

      assert :ok = RateLimiter.check_qr_login_rate_limit("2001:db8:#{net}:2::1")
    end
  end

  describe "IPv6 /64 grouping on login and mail IP buckets" do
    # QR already covers check_qr_login_rate_limit/1. Login keys the IP
    # itself; the mail endpoints go through charge_ip/4. A revert of either
    # call site must fail without the QR test catching it.
    test "login IP bucket is the /64", %{unique_id: id} do
      net = Integer.to_string(rem(id, 0xFFFF), 16)
      # login IP limit is login_limit * 3 = 15
      for n <- 1..15 do
        assert :ok =
                 RateLimiter.check_login_rate_limit(
                   "login6_#{id}_#{n}@e.com",
                   "2001:db8:#{net}:1::#{n}"
                 )
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_login_rate_limit(
                 "login6_#{id}_16@e.com",
                 "2001:db8:#{net}:1:dead:beef:0:99"
               )

      assert :ok =
               RateLimiter.check_login_rate_limit(
                 "login6_#{id}_other@e.com",
                 "2001:db8:#{net}:2::1"
               )
    end

    test "mail IP bucket is the /64", %{unique_id: id} do
      net = Integer.to_string(rem(id, 0xFFFF), 16)

      for n <- 1..10 do
        assert :ok =
                 RateLimiter.check_password_reset_rate_limit(
                   "spray6_#{id}_#{n}@e.com",
                   "2001:db8:#{net}:1::#{n}"
                 )
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(
                 "spray6_#{id}_11@e.com",
                 "2001:db8:#{net}:1:dead:beef:0:99"
               )

      assert :ok =
               RateLimiter.check_password_reset_rate_limit(
                 "spray6_#{id}_other@e.com",
                 "2001:db8:#{net}:2::1"
               )
    end
  end

  describe "get_remaining_attempts/2" do
    test "returns correct remaining attempts for login", %{unique_id: id} do
      email = "remaining_login_#{id}@example.com"

      # Initially should have 5 attempts remaining (default limit)
      assert 5 = RateLimiter.get_remaining_attempts(:login, email)

      # After one attempt, should have 4 remaining
      RateLimiter.check_login_rate_limit(email)
      assert 4 = RateLimiter.get_remaining_attempts(:login, email)

      # After 5 attempts, should have 0 remaining
      for _ <- 1..4 do
        RateLimiter.check_login_rate_limit(email)
      end

      assert 0 = RateLimiter.get_remaining_attempts(:login, email)
    end

    test "returns correct remaining attempts for magic link", %{unique_id: id} do
      email = "remaining_magic_#{id}@example.com"

      # Initially should have 3 attempts remaining (default limit)
      assert 3 = RateLimiter.get_remaining_attempts(:magic_link, email)

      # After one attempt, should have 2 remaining
      RateLimiter.check_magic_link_rate_limit(email)
      assert 2 = RateLimiter.get_remaining_attempts(:magic_link, email)
    end
  end

  # The address bucket cannot see a spray: every address takes a single hit, so
  # none of them ever fires and the install sends one email per address asked
  # for. These cover the two buckets that can.
  describe "per-IP bucket on the mail-sending endpoints" do
    test "a spray of fresh addresses from one IP is stopped", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 200)}"

      # Ten distinct addresses, one hit each — the per-address bucket (3) never
      # fires, and before the IP bucket existed all ten went through.
      for n <- 1..10 do
        assert :ok = RateLimiter.check_password_reset_rate_limit("spray_#{id}_#{n}@e.com", ip)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit("spray_#{id}_11@e.com", ip)
    end

    test "another IP is unaffected", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 200)}"

      for n <- 1..10 do
        assert :ok = RateLimiter.check_magic_link_rate_limit("ipa_#{id}_#{n}@e.com", ip)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_magic_link_rate_limit("ipa_#{id}_11@e.com", ip)

      assert :ok = RateLimiter.check_magic_link_rate_limit("ipb_#{id}@e.com", "203.0.113.42")
    end

    test "each endpoint has its own IP bucket", %{unique_id: id} do
      ip = "198.51.100.#{rem(id, 200)}"

      for n <- 1..10 do
        assert :ok = RateLimiter.check_confirmation_resend_rate_limit("mix_#{id}_#{n}@e.com", ip)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_confirmation_resend_rate_limit("mix_#{id}_11@e.com", ip)

      # Exhausting one endpoint must not close the others for that IP.
      assert :ok = RateLimiter.check_password_reset_rate_limit("mix2_#{id}@e.com", ip)
    end

    test "a request with no IP still gets the address bucket", %{unique_id: id} do
      email = "noip_#{id}@example.com"

      for _ <- 1..3 do
        assert :ok = RateLimiter.check_password_reset_rate_limit(email, nil)
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit(email, nil)
    end

    test "an unreadable address is treated as no IP, not as one shared bucket",
         %{unique_id: id} do
      # Lumping every unknown-IP visitor into one bucket would let a host that
      # cannot read peer data lock out its own users site-wide.
      for n <- 1..12 do
        assert :ok =
                 RateLimiter.check_password_reset_rate_limit("unk_#{id}_#{n}@e.com", "unknown")
      end
    end
  end

  # The site-wide cap. Switched off in config/test.exs (one counter shared by
  # the whole run), so these turn it on for themselves and put it back.
  describe "site-wide cap" do
    setup do
      previous = Application.get_env(:phoenix_kit, RateLimiter, [])

      on_exit(fn -> Application.put_env(:phoenix_kit, RateLimiter, previous) end)

      {:ok, previous: previous}
    end

    defp with_global_limit(previous, key, limit) do
      Application.put_env(:phoenix_kit, RateLimiter, Keyword.put(previous, key, limit))
    end

    test "refuses everyone once the install's hourly allowance is spent", %{previous: previous} do
      with_global_limit(previous, :password_reset_global_limit, 3)
      id = :erlang.unique_integer([:positive])

      # Distinct address AND distinct IP each time, so neither narrower bucket
      # is what stops it — only the site-wide one can.
      for n <- 1..3 do
        assert :ok =
                 RateLimiter.check_password_reset_rate_limit("g_#{id}_#{n}@e.com", "10.0.0.#{n}")
      end

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_password_reset_rate_limit("g_#{id}_4@e.com", "10.0.0.4")
    end

    test "a request the address bucket already refused does not spend it",
         %{previous: previous} do
      with_global_limit(previous, :magic_link_global_limit, 5)
      id = :erlang.unique_integer([:positive])
      victim = "victim_#{id}@example.com"

      # Three accepted (the address limit), then hammer the same address: those
      # are refused and send nothing, so they must not drain everyone's
      # allowance — charging the cap first would make this the whole DoS.
      for _ <- 1..3, do: RateLimiter.check_magic_link_rate_limit(victim, "10.1.0.1")
      for _ <- 1..20, do: RateLimiter.check_magic_link_rate_limit(victim, "10.1.0.1")

      # Two of the five are left for everybody else.
      assert :ok = RateLimiter.check_magic_link_rate_limit("other_#{id}_a@e.com", "10.1.0.2")
      assert :ok = RateLimiter.check_magic_link_rate_limit("other_#{id}_b@e.com", "10.1.0.3")

      assert {:error, :rate_limit_exceeded} =
               RateLimiter.check_magic_link_rate_limit("other_#{id}_c@e.com", "10.1.0.4")
    end

    test "nil switches the cap off", %{previous: previous} do
      with_global_limit(previous, :confirmation_resend_global_limit, nil)
      id = :erlang.unique_integer([:positive])

      for n <- 1..25 do
        assert :ok =
                 RateLimiter.check_confirmation_resend_rate_limit(
                   "off_#{id}_#{n}@e.com",
                   "10.2.0.#{n}"
                 )
      end
    end
  end
end
