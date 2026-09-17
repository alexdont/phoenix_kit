defmodule PhoenixKit.Integration.Languages.DefaultLanguageNoPrefixTest do
  @moduledoc """
  DB-backed coverage for the site-wide `default_language_no_prefix`
  setting that controls primary-language URL emission across the
  workspace.

  Pairs with `test/phoenix_kit/utils/routes_test.exs` (no-DB) which
  covers the OFF branch via the rescue path. This file pins the ON
  branch end-to-end (setter → getter → Routes helpers → sitemap) and
  the legacy-key migration.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  describe "default_language_no_prefix?/0 + set/1" do
    test "defaults to false when the key is unset" do
      refute Languages.default_language_no_prefix?()
    end

    test "round-trips a true value" do
      assert {:ok, _} = Languages.set_default_language_no_prefix(true)
      assert Languages.default_language_no_prefix?()
    end

    test "round-trips false explicitly" do
      assert {:ok, _} = Languages.set_default_language_no_prefix(true)
      assert {:ok, _} = Languages.set_default_language_no_prefix(false)
      refute Languages.default_language_no_prefix?()
    end
  end

  describe "Routes helpers honor the setting" do
    setup do
      Settings.update_setting("languages_enabled", "true")
      :ok
    end

    test "admin_path strips primary prefix only when setting is ON" do
      assert {:ok, _} = Languages.set_default_language_no_prefix(false)
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/en/admin/users"

      assert {:ok, _} = Languages.set_default_language_no_prefix(true)
      assert Routes.admin_path("/admin/users", "en") == "/phoenix_kit/admin/users"
    end

    test "admin_path always emits non-primary prefix regardless of setting" do
      assert {:ok, _} = Languages.set_default_language_no_prefix(true)
      assert Routes.admin_path("/admin/users", "de") == "/phoenix_kit/de/admin/users"

      assert {:ok, _} = Languages.set_default_language_no_prefix(false)
      assert Routes.admin_path("/admin/users", "de") == "/phoenix_kit/de/admin/users"
    end

    test "path/2 (non-admin) strips primary prefix only when setting is ON" do
      assert {:ok, _} = Languages.set_default_language_no_prefix(false)
      assert Routes.path("/users/log-in", locale: "en") == "/phoenix_kit/en/users/log-in"

      assert {:ok, _} = Languages.set_default_language_no_prefix(true)
      assert Routes.path("/users/log-in", locale: "en") == "/phoenix_kit/users/log-in"
    end
  end

  describe "the switcher's session-locale check with the setting ON" do
    alias PhoenixKitWeb.Components.Core.LanguageSwitcher

    setup do
      Settings.update_setting("languages_enabled", "true")
      {:ok, _} = Languages.set_default_language_no_prefix(true)
      :ok
    end

    # `Routes.path("/")` for the default language is "/phoenix_kit/" — the
    # prefixed mount's root with a trailing slash, the same page.
    test "the default language at a prefixed install's root is not a session-locale page" do
      refute LanguageSwitcher.session_locale_page?("en", "/phoenix_kit")
      refute LanguageSwitcher.session_locale_page?("en", "/phoenix_kit/")
      refute LanguageSwitcher.session_locale_page?("en", "/phoenix_kit/some/page")
      refute LanguageSwitcher.session_locale_page?("en", "/phoenix_kit?page=2")
    end

    test "another language at that root still is" do
      assert LanguageSwitcher.session_locale_page?("fr", "/phoenix_kit")
    end

    # `Routes.path/2` puts the mount prefix on every built URL, host pages
    # outside the mount included; the check compares both sides without it.
    test "a host page outside the mount is judged without the mount prefix" do
      refute LanguageSwitcher.session_locale_page?("en", "/products")
      assert LanguageSwitcher.session_locale_page?("fr", "/products")
    end
  end

  describe "migrate_legacy/0 — backfills from publishing key" do
    test "no-op when neither key is set" do
      assert {:ok, %{default_language_no_prefix: :not_migrated}} =
               Languages.migrate_legacy()

      refute Languages.default_language_no_prefix?()
    end

    test "no-op when the new key is already set (ignores legacy)" do
      # New key explicitly set to false; legacy is true. New wins.
      Settings.update_setting("default_language_no_prefix", "false")
      Settings.update_setting("publishing_default_language_no_prefix", "true")

      assert {:ok, %{default_language_no_prefix: :already_set}} =
               Languages.migrate_legacy()

      refute Languages.default_language_no_prefix?()
    end

    test "copies legacy true value to the new key" do
      Settings.update_setting("publishing_default_language_no_prefix", "true")
      refute Languages.default_language_no_prefix?()

      assert {:ok, %{default_language_no_prefix: :migrated_from_legacy, value: "true"}} =
               Languages.migrate_legacy()

      assert Languages.default_language_no_prefix?()
    end

    test "copies legacy false value to the new key" do
      Settings.update_setting("publishing_default_language_no_prefix", "false")

      assert {:ok, %{default_language_no_prefix: :migrated_from_legacy, value: "false"}} =
               Languages.migrate_legacy()

      assert Settings.get_setting("default_language_no_prefix") == "false"
      refute Languages.default_language_no_prefix?()
    end

    test "is idempotent — second run is a no-op" do
      Settings.update_setting("publishing_default_language_no_prefix", "true")

      assert {:ok, %{default_language_no_prefix: :migrated_from_legacy}} =
               Languages.migrate_legacy()

      assert {:ok, %{default_language_no_prefix: :already_set}} =
               Languages.migrate_legacy()
    end
  end

  describe "prefixless_primary_safe?/0 — boot-safe wrapper" do
    test "returns the same value as default_language_no_prefix?/0 from runtime" do
      refute Languages.prefixless_primary_safe?()

      Languages.set_default_language_no_prefix(true)
      assert Languages.prefixless_primary_safe?()

      Languages.set_default_language_no_prefix(false)
      refute Languages.prefixless_primary_safe?()
    end

    test "returns false in mix-task context regardless of setting" do
      Languages.set_default_language_no_prefix(true)

      # Mark the process as in mix-task context — same sentinel
      # `Routes.path/1` checks
      Process.put(:phoenix_kit_config_status, :mix_task)
      refute Languages.prefixless_primary_safe?()

      Process.delete(:phoenix_kit_config_status)
      assert Languages.prefixless_primary_safe?()
    end
  end
end
