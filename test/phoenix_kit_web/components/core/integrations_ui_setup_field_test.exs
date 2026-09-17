defmodule PhoenixKitWeb.Components.Core.IntegrationsUISetupFieldTest do
  @moduledoc """
  When `setup_field/1` marks its input `required`. A masked secret renders
  empty and empty means "keep the saved one", so a required secret blocked
  "Save Changes" in the browser until it was typed again.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.IntegrationsUI

  @secret %{key: "password", label: "API password", type: :password, required: true}
  @login %{key: "login", label: "API login", type: :text, required: true}

  defp input(field, typed \\ "", saved \\ "") do
    html =
      render_component(&IntegrationsUI.setup_field/1,
        field: field,
        typed_value: typed,
        saved_value: saved
      )

    [tag] = Regex.run(~r/<input[^>]*>/, html)
    tag
  end

  test "a required secret with nothing saved is required" do
    assert input(@secret) =~ "required"
  end

  test "a saved secret left blank is not required" do
    refute input(@secret, "", "saved-secret") =~ "required"
  end

  test "a saved secret being replaced is required again" do
    assert input(@secret, "new-secret", "saved-secret") =~ "required"
  end

  test "other fields keep their own flag, saved or not" do
    assert input(@login, "", "you@example.com") =~ "required"
    refute input(%{@login | required: false}) =~ "required"
  end

  test "a provider that leaves required nil gets an optional field, not a crash" do
    refute input(%{@login | required: nil}) =~ "required"
    refute input(%{@secret | required: nil}, "", "saved-secret") =~ "required"
  end
end
