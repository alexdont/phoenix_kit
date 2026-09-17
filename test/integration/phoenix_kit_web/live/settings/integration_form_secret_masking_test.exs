defmodule PhoenixKitWeb.Live.Settings.IntegrationFormSecretMaskingTest do
  @moduledoc """
  D011: a saved credential must never round-trip into the rendered HTML of
  the system integration setup form (`/admin/settings/integrations/:uuid`).

  Uses `aws_ses` as the exercising provider — it mixes a non-sensitive
  required field (`access_key`, `aws_region`) with a sensitive one
  (`secret_key`), so one provider proves both "secret is masked" and
  "non-secret fields keep working" at once.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @new_path Routes.path("/admin/settings/integrations/new")

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()

    # Website integrations are gated by "integrations_system"; the test DB's
    # Admin role carries no permission rows (the auto-grant sweep runs at app
    # boot, not here) — see `integrations_test.exs` for the same fixture.
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")

    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  defp seed_aws_ses(secret) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", "prod ses")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "access_key" => "AKIAEXAMPLE123",
        "secret_key" => secret,
        "aws_region" => "eu-central-1"
      })

    uuid
  end

  describe "new connection (nothing saved yet)" do
    setup :setup_admin

    test "the secret field is empty and shows the provider's own placeholder, not a saved indicator",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      html =
        view
        |> element(~s(button[phx-value-provider="aws_ses"]))
        |> render_click()

      refute html =~ "already configured"
      assert html =~ ~s(placeholder="...")
      assert html =~ ~s(name="secret_key" id="field-secret_key" value="")

      # Nothing saved yet, so the secret is required like any other field.
      [secret_input] = Regex.run(~r/<input[^>]*name="secret_key"[^>]*>/, html)
      assert secret_input =~ "required"
    end
  end

  describe "editing a connection with a saved secret" do
    setup :setup_admin

    test "the saved secret never appears in the rendered HTML", %{conn: conn} do
      secret = "AwsSecretKey-#{System.unique_integer([:positive])}"
      uuid = seed_aws_ses(secret)

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      refute html =~ secret
    end

    test "the operator sees the S009 'already configured' placeholder instead of the secret",
         %{conn: conn} do
      secret = "AwsSecretKey-#{System.unique_integer([:positive])}"
      uuid = seed_aws_ses(secret)

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      assert html =~ "A secret is already configured — leave blank to keep the current value"
      assert html =~ ~s(name="secret_key" id="field-secret_key" value="")
    end

    test "the masked secret is not required, so Save Changes works without retyping it",
         %{conn: conn} do
      uuid = seed_aws_ses("AwsSecretKey-irrelevant")

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      [secret_input] = Regex.run(~r/<input[^>]*name="secret_key"[^>]*>/, html)
      [access_input] = Regex.run(~r/<input[^>]*name="access_key"[^>]*>/, html)
      refute secret_input =~ "required"
      assert access_input =~ "required"
    end

    test "non-secret fields keep showing their saved value", %{conn: conn} do
      uuid = seed_aws_ses("AwsSecretKey-irrelevant")

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      assert html =~ "AKIAEXAMPLE123"
      assert html =~ "eu-central-1"
    end
  end

  describe "saving the edit form without touching the masked secret" do
    setup :setup_admin

    test "submitting with the secret field blank keeps the original secret", %{conn: conn} do
      secret = "AwsSecretKey-#{System.unique_integer([:positive])}"
      uuid = seed_aws_ses(secret)

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      view
      |> element(~s(form[phx-submit="save_form"]))
      |> render_submit(%{
        "access_key" => "AKIAEXAMPLE123",
        # Left blank, as the masked field renders — must NOT overwrite the
        # saved secret with an empty string.
        "secret_key" => "",
        "aws_region" => "eu-central-1"
      })

      {:ok, %{data: data}} = Integrations.get_integration_by_uuid(uuid, :system)
      assert data["secret_key"] == secret
    end
  end

  describe "Test, then Create" do
    setup :setup_admin

    test "the edit page Create lands on does not echo the secret typed on /new", %{conn: conn} do
      typed_secret = "typed-then-saved-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element(~s(button[phx-value-provider="aws_ses"]))
      |> render_click()

      fields = %{
        "access_key" => "AKIAEXAMPLE123",
        "secret_key" => typed_secret,
        # Blank region -> Validators.aws_ses/1 fails locally, no network call.
        "aws_region" => ""
      }

      # The dry run keeps the typed values on screen, as it should on /new.
      assert view
             |> element(~s(form[phx-submit="save_form"]))
             |> render_submit(Map.put(fields, "_intent", "test")) =~ typed_secret

      view
      |> element(~s(form[phx-submit="save_form"]))
      |> render_submit(Map.put(fields, "name", "typed ses"))

      path = assert_patch(view)
      assert path =~ "/admin/settings/integrations/"

      html = render(view)
      assert html =~ "A secret is already configured — leave blank to keep the current value"
      refute html =~ typed_secret
    end
  end

  describe "a failed dry-run test on /new preserves what the operator typed" do
    setup :setup_admin

    test "the just-typed secret is NOT swallowed by masking when the test fails", %{conn: conn} do
      typed_secret = "just-typed-secret-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element(~s(button[phx-value-provider="aws_ses"]))
      |> render_click()

      html =
        view
        |> element(~s(form[phx-submit="save_form"]))
        |> render_submit(%{
          "_intent" => "test",
          "access_key" => "AKIAEXAMPLE123",
          "secret_key" => typed_secret,
          # Blank region -> Validators.aws_ses/1 fails locally, no network call.
          "aws_region" => ""
        })

      assert html =~ "Test failed"
      assert html =~ typed_secret
    end
  end
end
