defmodule PhoenixKit.Modules.Sitemap.PublicBaseUrlTest do
  @moduledoc """
  Which endpoint URLs the sitemap may publish when `site_url` is unset.

  A sitemap goes to crawlers, so the fallback refuses what cannot be the
  site's address: placeholder hosts always (phx.new's production default is
  `example.com`), loopback hosts except on a development server (Phoenix's
  default host is `localhost`).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap

  test "a public URL is used, without its trailing slash" do
    assert Sitemap.public_base_url("https://shop.acme.dev/", false) == "https://shop.acme.dev"
    assert Sitemap.public_base_url("http://10.0.0.5:4000", false) == "http://10.0.0.5:4000"
  end

  test "placeholder hosts never count, dev server or not" do
    for url <- [
          "https://example.com",
          "https://EXAMPLE.org",
          "https://www.example.net",
          "http://shop.example",
          "http://site.invalid",
          "https://www.example.com."
        ],
        dev? <- [true, false] do
      assert Sitemap.public_base_url(url, dev?) == "", "#{url} dev=#{dev?}"
    end
  end

  test "a name that merely contains a placeholder or local name is a real host" do
    for url <- [
          "https://myexample.com",
          "https://example.com.au",
          "https://localhost.company.com",
          "https://test.acme.dev",
          "http://[::ffff:10.0.0.5]"
        ] do
      assert Sitemap.public_base_url(url, false) == url, url
    end
  end

  test "local hosts count only on a development server" do
    for url <- [
          "http://localhost:4000",
          "http://LocalHost",
          "http://localhost.:4000",
          "http://app.localhost:4000",
          "http://127.0.0.1:4000",
          "http://127.1.2.3",
          "http://127.1",
          "http://2130706433",
          "http://[::1]:4000",
          "http://[::ffff:127.0.0.1]:4000",
          "http://[::ffff:7f00:1]",
          "http://[::127.0.0.1]",
          "http://0.0.0.0:4000",
          "http://[::]:4000",
          "http://shop.test:4000"
        ] do
      assert Sitemap.public_base_url(url, false) == "", url
      assert Sitemap.public_base_url(url, true) == url, url
    end
  end

  test "anything but an absolute http(s) URL is refused" do
    for url <- ["", "/relative", "ftp://files.acme.dev", "https://", "shop.acme.dev"] do
      assert Sitemap.public_base_url(url, true) == "", inspect(url)
    end
  end
end
