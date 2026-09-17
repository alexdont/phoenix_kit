defmodule PhoenixKitWeb.Users.AuthPageTitleTest do
  @moduledoc """
  What the browser tab says on an auth page.

  The kit's auth pages used to assign no `page_title` at all — the string they
  built was handed to a layout wrapper that ignores it unless the host layout is
  in use. A host root layout of `<.live_title default="App" suffix=" · App">`
  therefore rendered "App · App", and the page never got a say.

  The contract: the PAGE supplies its own name and nothing else, the ROOT layout
  supplies the brand. So a title contains the page's name, and never the project
  name twice.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Settings

  defp title_of(html) do
    case Regex.run(~r{<title[^>]*>(.*?)</title>}s, html) do
      [_, title] -> title |> String.replace(~r/\s+/, " ") |> String.trim()
      nil -> nil
    end
  end

  describe "auth pages name themselves" do
    test "the log-in page's title is the page, not the project twice", %{conn: conn} do
      project = Settings.get_project_title()

      html = conn |> get("/phoenix_kit/users/log-in") |> html_response(200)
      title = title_of(html)

      assert title =~ "Log in", "the page must supply its own name"

      refute title =~ ~r/#{Regex.escape(project)}.*#{Regex.escape(project)}/,
             "the project name appeared twice in #{inspect(title)}"
    end

    test "registration names itself too", %{conn: conn} do
      html = conn |> get("/phoenix_kit/users/register") |> html_response(200)

      assert title_of(html) =~ "Register"
    end

    test "the kit's root layout adds no framework branding", %{conn: conn} do
      html = conn |> get("/phoenix_kit/users/log-in") |> html_response(200)

      refute title_of(html) =~ "Phoenix Framework",
             "a stock phx.new suffix shipped as every install's tab branding"
    end
  end
end
