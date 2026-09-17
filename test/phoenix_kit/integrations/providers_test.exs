defmodule PhoenixKit.Integrations.ProvidersTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Providers

  describe "all/0" do
    test "returns a list of provider maps" do
      providers = Providers.all()
      assert is_list(providers)
      assert length(providers) >= 2
    end

    test "includes google provider" do
      providers = Providers.all()
      google = Enum.find(providers, &(&1.key == "google"))
      assert google != nil
      assert google.name == "Google"
      assert google.auth_type == :oauth2
      assert google.oauth_config != nil
      assert google.oauth_config[:auth_url] =~ "accounts.google.com"
      assert google.oauth_config[:token_url] =~ "oauth2.googleapis.com"
      assert google.oauth_config[:userinfo_url] =~ "googleapis.com/oauth2"
    end

    test "includes openrouter provider" do
      providers = Providers.all()
      openrouter = Enum.find(providers, &(&1.key == "openrouter"))
      assert openrouter != nil
      assert openrouter.name == "OpenRouter"
      assert openrouter.auth_type == :api_key
      assert openrouter.oauth_config == nil
    end

    test "google has required setup fields" do
      google = Providers.get("google")
      field_keys = Enum.map(google.setup_fields, & &1.key)
      assert "client_id" in field_keys
      assert "client_secret" in field_keys
    end

    test "openrouter has required setup fields" do
      openrouter = Providers.get("openrouter")
      field_keys = Enum.map(openrouter.setup_fields, & &1.key)
      assert "api_key" in field_keys
    end

    test "all providers have required keys" do
      for provider <- Providers.all() do
        assert is_binary(provider.key), "provider missing key"
        assert is_binary(provider.name), "#{provider.key} missing name"
        assert is_binary(provider.description), "#{provider.key} missing description"
        assert is_binary(provider.icon), "#{provider.key} missing icon"
        assert provider.auth_type in [:oauth2, :api_key, :key_secret, :bot_token, :credentials]
        assert is_list(provider.setup_fields), "#{provider.key} missing setup_fields"
        assert is_list(provider.capabilities), "#{provider.key} missing capabilities"
      end
    end
  end

  describe "aws_ses provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("aws_ses")
      assert p.auth_type == :key_secret
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "access_key" in keys and "secret_key" in keys and "aws_region" in keys
      assert "secret_key" in Encryption.sensitive_fields()
      assert :email_send in p.capabilities

      # end-to-end: headless save must yield retrievable credentials
      {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "test")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "aws_region" => "eu-central-1"
        })

      assert {:ok, %{"access_key" => "AKIA_T"}} = Integrations.get_credentials(uuid)
    end
  end

  describe "object_storage provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("object_storage")
      assert p.auth_type == :key_secret
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "access_key" in keys and "secret_key" in keys
      assert "region" in keys and "endpoint" in keys
      assert "secret_key" in Encryption.sensitive_fields()

      required = p.setup_fields |> Enum.filter(& &1.required) |> Enum.map(& &1.key)
      assert "access_key" in required and "secret_key" in required
      refute "region" in required
      refute "endpoint" in required

      # end-to-end: headless save must yield retrievable credentials
      {:ok, %{uuid: uuid}} = Integrations.add_connection("object_storage", "test")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "access_key" => "AKIA_T",
          "secret_key" => "S",
          "region" => "eu-central-1",
          "endpoint" => "s3.eu-central-003.backblazeb2.com"
        })

      assert {:ok, %{"access_key" => "AKIA_T", "endpoint" => "s3.eu-central-003.backblazeb2.com"}} =
               Integrations.get_credentials(uuid)
    end
  end

  describe "smtp provider (universal)" do
    test "is registered and produces usable credentials, with multiple named connections" do
      p = Providers.get("smtp")
      assert p.auth_type == :credentials
      assert p.oauth_config == nil
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "host" in keys and "port" in keys and "username" in keys and "password" in keys
      assert "password" in Encryption.sensitive_fields()
      assert :email_send in p.capabilities

      # end-to-end: headless save + validate must yield retrievable credentials
      {:ok, %{uuid: uuid1}} = Integrations.add_connection("smtp", "SMTP 1")

      {:ok, _} =
        Integrations.save_setup(uuid1, %{
          "host" => "smtp-relay.brevo.com",
          "port" => "587",
          "username" => "sub1@smtp-brevo.com",
          "password" => "not-a-real-smtp-secret"
        })

      # No validate_connection here on purpose: SMTP is now validated for real
      # (a live session + AUTH), so fabricated credentials are rejected -- which
      # is the point. Retrievability comes from save_setup stamping "configured"
      # once every required flat field is present.
      assert {:ok, %{"host" => "smtp-relay.brevo.com", "password" => "not-a-real-smtp-secret"}} =
               Integrations.get_credentials(uuid1)

      # a second named connection of the same provider coexists independently
      {:ok, %{uuid: uuid2}} = Integrations.add_connection("smtp", "SMTP 2")

      {:ok, _} =
        Integrations.save_setup(uuid2, %{
          "host" => "smtp.example.com",
          "port" => "2525",
          "username" => "user2",
          "password" => "pw2"
        })

      assert {:ok, %{"host" => "smtp.example.com"}} = Integrations.get_credentials(uuid2)

      connections = Integrations.list_connections("smtp")
      uuids = Enum.map(connections, & &1.uuid)
      assert uuid1 in uuids and uuid2 in uuids
    end

    test "a login is optional, so an IP-authenticated relay is configurable at all" do
      # SmtpTransport has always had a credential-less branch (opportunistic
      # TLS, degrade instead of :no_ca_store), and the transport settings offer
      # `auth: never` for "relays that authenticate by IP" — but marking
      # username/password required made every one of those unreachable: the form
      # refused to submit, and `has_flat_credential_fields?/2` refused to call
      # the connection configured.
      p = Providers.get("smtp")
      required = p.setup_fields |> Enum.filter(& &1.required) |> Enum.map(& &1.key)

      assert "host" in required
      assert "port" in required
      refute "username" in required
      refute "password" in required

      {:ok, %{uuid: uuid}} = Integrations.add_connection("smtp", "internal relay")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "host" => "relay.internal",
          "port" => "25",
          "username" => "",
          "password" => "",
          "security" => "none",
          "auth" => "never"
        })

      assert {:ok, %{"host" => "relay.internal"}} = Integrations.get_credentials(uuid)
    end

    test "Test Connection really connects: an unreachable relay is rejected" do
      # Before the validators existed this returned :ok and the connection was
      # stamped "connected" -- a green check on a relay that does not exist.
      {:ok, %{uuid: uuid}} = Integrations.add_connection("smtp", "dead relay")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "host" => "127.0.0.1",
          "port" => "1",
          "username" => "u",
          "password" => "p"
        })

      assert {:error, _reason} = Integrations.validate_connection(uuid)
    end
  end

  describe "brevo_api provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("brevo_api")
      assert p.auth_type == :api_key
      assert p.oauth_config == nil
      assert p.base_url == "https://api.brevo.com/v3"
      keys = Enum.map(p.setup_fields, & &1.key)
      assert "api_key" in keys
      assert "api_key" in Encryption.sensitive_fields()
      assert :email_send in p.capabilities

      {:ok, %{uuid: uuid}} = Integrations.add_connection("brevo_api", "test")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "xkeysib-test"})

      assert {:ok, %{"api_key" => "xkeysib-test"}} = Integrations.get_credentials(uuid)
    end
  end

  describe "dataforseo provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("dataforseo")
      assert p.auth_type == :key_secret
      assert p.oauth_config == nil
      assert p.validation == %{strategy: :dataforseo}
      assert Providers.scopes_of(p) == [:system]
      assert :search_results in p.capabilities

      required = p.setup_fields |> Enum.filter(& &1.required) |> Enum.map(& &1.key)
      assert required == ["login", "password"]
      assert "password" in Encryption.sensitive_fields()

      {:ok, %{uuid: uuid}} = Integrations.add_connection("dataforseo", "default")

      {:ok, _} =
        Integrations.save_setup(uuid, %{"login" => "you@example.com", "password" => "api-secret"})

      assert {:ok, %{"login" => "you@example.com", "password" => "api-secret"}} =
               Integrations.get_credentials(uuid)

      # The password is encrypted at rest; the login is not a secret.
      stored = PhoenixKit.Settings.get_json_setting_by_uuid(uuid)
      assert stored["login"] == "you@example.com"
      refute stored["password"] == "api-secret"

      # A bare provider key resolves too.
      assert {:ok, %{"password" => "api-secret"}} = Integrations.get_credentials("dataforseo")
    end

    test "is not configured until both the login and the password are saved" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("dataforseo", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{"login" => "you@example.com"})

      refute Integrations.connected?(uuid)
      assert {:error, "Not configured"} = Integrations.validate_connection(uuid)
    end

    test "Test Connection runs the DataForSEO check, not the generic fallback" do
      # The catch-all would answer :unverified for a :key_secret provider.
      assert {:error, "No credentials configured"} =
               Integrations.__do_validate__(Providers.get("dataforseo"), %{})
    end
  end

  describe "serpapi provider" do
    test "is registered and produces usable credentials" do
      p = Providers.get("serpapi")
      assert p.auth_type == :api_key
      assert p.oauth_config == nil
      assert p.validation == %{strategy: :serpapi}
      assert Providers.scopes_of(p) == [:system]
      assert :search_results in p.capabilities
      assert Enum.map(p.setup_fields, & &1.key) == ["api_key"]
      assert "api_key" in Encryption.sensitive_fields()

      {:ok, %{uuid: uuid}} = Integrations.add_connection("serpapi", "default")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "serp-key"})

      assert {:ok, %{"api_key" => "serp-key"}} = Integrations.get_credentials(uuid)
      assert {:ok, %{"api_key" => "serp-key"}} = Integrations.get_credentials("serpapi")
      refute PhoenixKit.Settings.get_json_setting_by_uuid(uuid)["api_key"] == "serp-key"
    end

    test "Test Connection runs the SerpApi check, not the generic header check" do
      # A whitespace key tells the two apart without a request: the SerpApi
      # check treats it as blank, while the generic clause would take it as a
      # key and look for a header URL this provider does not declare.
      assert {:error, "No credentials configured"} =
               Integrations.__do_validate__(Providers.get("serpapi"), %{"api_key" => "   "})
    end
  end

  describe "get/1" do
    test "returns provider for known key" do
      assert %{key: "google"} = Providers.get("google")
      assert %{key: "openrouter"} = Providers.get("openrouter")
    end

    test "returns nil for unknown key" do
      assert Providers.get("nonexistent") == nil
      assert Providers.get("") == nil
    end
  end

  describe "used_by_modules/0" do
    test "returns a map" do
      result = Providers.used_by_modules()
      assert is_map(result)
    end
  end

  describe "clear_cache/0" do
    test "clears and repopulates on next call" do
      # Populate cache
      providers1 = Providers.all()
      assert is_list(providers1)

      # Clear
      :ok = Providers.clear_cache()

      # Should repopulate
      providers2 = Providers.all()
      assert providers1 == providers2
    end

    test "safe to call when cache is empty" do
      Providers.clear_cache()
      assert :ok = Providers.clear_cache()
    end
  end

  describe "telegram provider instructions" do
    test "tell the operator how to link a chat, not only how to make a bot" do
      # A token alone delivers nothing: until a chat is linked the channel has
      # nowhere to send. The instructions used to stop at "paste the token".
      steps =
        Providers.get("telegram").instructions
        |> Enum.flat_map(& &1.steps)
        |> Enum.map_join(" ", fn {text, _} -> text end)

      assert steps =~ "/start"
    end

    test "cover linking a group, which needs a command the bot can see" do
      steps =
        Providers.get("telegram").instructions
        |> Enum.flat_map(& &1.steps)
        |> Enum.map_join(" ", fn {text, _} -> text end)

      assert steps =~ "group"
    end
  end
end
