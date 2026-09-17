defmodule PhoenixKitWeb.Components.ImageEditorTest do
  @moduledoc """
  The image editor component, driven the way a person drives it: the form
  alone (no hook), the buttons, and the `drawn` events the hook sends.

  Real bucket, real ImageMagick, Oban in manual mode; the host LiveView
  forwards `file_processed` like MediaBrowser and MediaDetail do.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ApplyImageEditJob
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.ImageEditor

  @endpoint PhoenixKitWeb.Endpoint
  @moduletag :tmp_dir

  # ExUnit cannot skip from `setup` (a `skip:` it returns is only context), so
  # the ImageMagick check is a module tag. `convert`/`identify` are what
  # `ImageProcessor` runs — ImageMagick 6 has no `magick` binary.
  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  @buckets_cache :phoenix_kit_buckets_cache
  @job_worker "PhoenixKit.Modules.Storage.ApplyImageEditJob"

  defmodule Host do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      user = session["user_uuid"] && Auth.get_user(session["user_uuid"])

      {:ok,
       socket
       |> assign(:file, Storage.get_file(session["file_uuid"]))
       |> assign(:scope, user && Scope.for_user(user))
       |> assign(:authorized, session["authorized"] == true)}
    end

    def handle_info({:processed, uuid}, socket) do
      send_update(ImageEditor, id: "editor", file_processed: uuid)
      {:noreply, socket}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={ImageEditor}
        id="editor"
        file={@file}
        scope={@scope}
        authorized={@authorized}
        on_close={Phoenix.LiveView.JS.push("close")}
      />
      """
    end
  end

  setup %{tmp_dir: tmp} do
    if match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true)) do
      :persistent_term.erase(@buckets_cache)
      n = System.unique_integer([:positive])
      Repo.update_all(Bucket, set: [enabled: false])

      {:ok, _} =
        Storage.create_bucket(%{
          name: "editor-ui-#{n}",
          provider: "local",
          endpoint: Path.join(tmp, "bucket"),
          enabled: true,
          priority: 0
        })

      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

      _first_user_is_owner = user!("first", n)
      owner = user!("owner", n)
      %{n: n, owner: owner, photo: upload!(owner, tmp)}
    else
      {:ok, skip: true}
    end
  end

  defp user!(name, n) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "#{name}-editor-ui-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  # 60x40, left half red, right half blue.
  defp upload!(user, dir) do
    path = Path.join(dir, "photo.png")

    {_, 0} =
      System.cmd("convert", [
        "-size",
        "30x40",
        "xc:red",
        "-size",
        "30x40",
        "xc:blue",
        "+append",
        path
      ])

    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", user.uuid, sha, "png", "photo.png")

    :ok =
      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "x"}})

    Storage.get_file(file.uuid)
  end

  defp open(file, opts) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{
          "file_uuid" => file.uuid,
          "user_uuid" => opts[:user] && opts[:user].uuid,
          "authorized" => Keyword.get(opts, :authorized, false)
        }
      )

    view
  end

  defp run_jobs(view, file) do
    for job <-
          Repo.all(from(j in Oban.Job, where: j.worker == @job_worker and j.state == "available")) do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
      :ok = ApplyImageEditJob.perform(%{job | attempt: 1})
    end

    send(view.pid, {:processed, file.uuid})
    # The host forwards it as a send_update, queued behind the next render.
    _ = render(view)
    render(view)
  end

  defp form(view), do: element(view, "#editor-form")

  defp crop_fields(x, y, w, h),
    do: %{"crop" => %{"x" => "#{x}", "y" => "#{y}", "w" => "#{w}", "h" => "#{h}"}}

  describe "without the hook" do
    test "a crop typed into the fields is previewed and saved", ctx do
      view = open(ctx.photo, user: ctx.owner)

      html = render_change(form(view), %{"edit" => crop_fields(0, 0, 50, 100)})
      # The kept part is outlined, the rest shaded.
      assert html =~ "left: 0%; top: 0%; width: 50%; height: 100%;"
      assert html =~ "Result: 30 × 40 px"

      html =
        view
        |> form()
        |> render_submit(%{"intent" => "save", "edit" => crop_fields(0, 0, 50, 100)})

      assert html =~ "Applying the edit"

      assert Storage.get_file(ctx.photo.uuid).edits == %{
               "crop" => %{"x" => 0.0, "y" => 0.0, "w" => 50.0, "h" => 100.0}
             }

      html = run_jobs(view, ctx.photo)
      refute html =~ "Applying the edit"
      assert html =~ "Unedited original"
      assert html =~ "/api/files/#{ctx.photo.uuid}/unedited?t="
      assert Storage.get_file(ctx.photo.uuid).width == 30
    end

    test "turning turns the frame and the crop with it", ctx do
      view = open(ctx.photo, user: ctx.owner)
      render_change(form(view), %{"edit" => crop_fields(0, 0, 50, 100)})

      html = view |> element("button[phx-value-to=right]") |> render_click()

      assert html =~ "aspect-ratio: 40 / 60"
      # The left half, turned a quarter to the right, is the top half.
      assert html =~ "left: 0%; top: 0%; width: 100%; height: 50%;"
      assert html =~ "rotate(90deg)"
    end

    test "mirroring is a toggle, kept while the fields change", ctx do
      view = open(ctx.photo, user: ctx.owner)

      assert view |> element("button[phx-value-axis=horizontal]") |> render_click() =~
               ~s(aria-pressed="true")

      # The form has no mirror field: a change must not drop it.
      html = render_change(form(view), %{"edit" => %{"brightness" => "10"}})
      assert html =~ ~s(aria-pressed="true")
      assert html =~ "scale(-1, 1)"

      refute view |> element("button[phx-value-axis=horizontal]") |> render_click() =~
               ~s(aria-pressed="true")
    end

    test "an aspect preset makes the largest centred crop", ctx do
      view = open(ctx.photo, user: ctx.owner)

      html = view |> element("button[phx-value-aspect='1:1']") |> render_click()
      # 40x40 of 60x40, centred.
      assert html =~ "width: 66.667%; height: 100%;"
      assert html =~ "left: 16.667%;"

      html = view |> element("button", "No crop") |> render_click()
      refute html =~ "height: 100%;\"></div>"
      refute html =~ "No crop"
    end

    test "areas are added, styled and removed", ctx do
      view = open(ctx.photo, user: ctx.owner)

      render_change(form(view), %{"tool" => "redact", "edit" => %{}})
      html = view |> element("button", "Add area") |> render_click()
      assert html =~ ~s(name="edit[redact][0][style]")

      html =
        render_change(form(view), %{
          "tool" => "redact",
          "edit" => %{
            "redact" => %{
              "0" => %{"x" => "5", "y" => "5", "w" => "30", "h" => "30", "style" => "fill"}
            }
          }
        })

      assert html =~ "bg-black"
      assert html =~ "left: 5%; top: 5%; width: 30%; height: 30%;"

      html = view |> element("button[aria-label='Remove area']") |> render_click()
      refute html =~ ~s(name="edit[redact][0][style]")
    end

    test "switching tools keeps the other tool's values", ctx do
      view = open(ctx.photo, user: ctx.owner)
      render_change(form(view), %{"edit" => crop_fields(10, 0, 50, 100)})

      # The crop fields travel hidden while the areas are shown.
      html =
        render_change(form(view), %{"tool" => "redact", "edit" => crop_fields(10, 0, 50, 100)})

      assert html =~ ~s(type="hidden" name="edit[crop][x]" value="10.0")
      assert html =~ "left: 10%; top: 0%; width: 50%; height: 100%;"
    end
  end

  describe "with the hook" do
    test "a drawn rectangle becomes the crop, or an area", ctx do
      view = open(ctx.photo, user: ctx.owner)

      html =
        view
        |> element("#editor-frame")
        |> render_hook("drawn", %{"tool" => "crop", "x" => 10, "y" => 10, "w" => 40, "h" => 40})

      assert html =~ "left: 10%; top: 10%; width: 40%; height: 40%;"

      render_change(form(view), %{"tool" => "redact", "edit" => crop_fields(10, 10, 40, 40)})

      html =
        view
        |> element("#editor-frame")
        |> render_hook("drawn", %{"tool" => "redact", "x" => 60, "y" => 0, "w" => 20, "h" => 20})

      assert html =~ ~s(name="edit[redact][0][x]")
      assert html =~ "left: 60%; top: 0%; width: 20%; height: 20%;"

      # A slip of the pointer, not a rectangle.
      html =
        view
        |> element("#editor-frame")
        |> render_hook("drawn", %{"tool" => "redact", "x" => 1, "y" => 1, "w" => 0.1, "h" => 0.1})

      refute html =~ ~s(name="edit[redact][1][x]")
    end

    test "a preview turned against the recorded size corrects the frame", ctx do
      view = open(ctx.photo, user: ctx.owner)
      assert render(view) =~ "aspect-ratio: 60 / 40"

      html = view |> element("#editor-frame") |> render_hook("turned_source", %{})
      assert html =~ "aspect-ratio: 40 / 60"
    end
  end

  describe "who may edit" do
    test "someone else sees no form", ctx do
      stranger = user!("stranger", ctx.n)
      html = render(open(ctx.photo, user: stranger))

      assert html =~ "You can&#39;t edit this image."
      refute html =~ "editor-form"
    end

    test "a host that authorized the user lets them edit", ctx do
      stranger = user!("stranger", ctx.n)
      view = open(ctx.photo, user: stranger, authorized: true)

      view |> form() |> render_submit(%{"intent" => "save", "edit" => %{"brightness" => "20"}})
      assert Storage.get_file(ctx.photo.uuid).edits == %{"brightness" => 20}
    end

    test "an annotated image offers no geometry, and says why", ctx do
      {:ok, _} =
        Annotations.create(%{
          file_uuid: ctx.photo.uuid,
          kind: "rectangle",
          geometry: %{"x" => 0.1, "y" => 0.1, "w" => 0.2, "h" => 0.2}
        })

      html = render(open(ctx.photo, user: ctx.owner))

      assert html =~ "This image has an annotation"
      refute html =~ ~s(phx-value-to="right")
      assert html =~ "Brightness"
    end
  end

  describe "the unedited original" do
    setup ctx do
      {:ok, _} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: Scope.for_user(ctx.owner))
      view = open(ctx.photo, user: ctx.owner)
      run_jobs(view, ctx.photo)
      %{view: view}
    end

    test "is restored only after confirming", ctx do
      html = ctx.view |> element("button[phx-value-action=revert]") |> render_click()
      assert html =~ "Undo the edit"
      assert Storage.get_file(ctx.photo.uuid).edits == %{"rotate" => 90}

      ctx.view |> element("button", "Restore original") |> render_click()
      assert Storage.get_file(ctx.photo.uuid).edit_state == "pending"

      html = run_jobs(ctx.view, ctx.photo)
      refute html =~ "Unedited original"
      assert Storage.get_file(ctx.photo.uuid).width == 60
    end

    test "is deleted for good only after confirming", ctx do
      html = ctx.view |> element("button[phx-value-action=delete_unedited]") |> render_click()
      assert html =~ "Delete the unedited original for good?"

      html = ctx.view |> element("button", "Cancel") |> render_click()
      refute html =~ "for good?"
      assert ImageEditing.edited?(Storage.get_file(ctx.photo.uuid))

      ctx.view |> element("button[phx-value-action=delete_unedited]") |> render_click()
      html = ctx.view |> element("button", "Delete for good") |> render_click()

      refute html =~ "Unedited original"
      refute ImageEditing.edited?(Storage.get_file(ctx.photo.uuid))
    end

    test "is the preview source, through a signed link", ctx do
      html = render(ctx.view)
      assert html =~ ~r{src="[^"]*/api/files/#{ctx.photo.uuid}/unedited\?t=[^"]*variant=large}
      # The frame is the unedited image turned by the saved edit.
      assert html =~ "aspect-ratio: 40 / 60"
    end
  end

  describe "failures" do
    test "a failed edit says so and can be retried", ctx do
      {:ok, _} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: Scope.for_user(ctx.owner))

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.photo.uuid),
        set: [edit_state: "failed"]
      )

      view = open(ctx.photo, user: ctx.owner)
      assert render(view) =~ "The edit could not be applied."

      view |> element("button", "Try again") |> render_click()
      assert Storage.get_file(ctx.photo.uuid).edit_state == "pending"
      assert render(view) =~ "Applying the edit"
    end

    test "a render that takes long can be started again", ctx do
      {:ok, _} = ImageEditing.edit(ctx.photo, %{"rotate" => 90}, scope: Scope.for_user(ctx.owner))
      view = open(ctx.photo, user: ctx.owner)
      refute render(view) =~ "Start again"

      long_ago = DateTime.add(DateTime.utc_now(), -300) |> DateTime.truncate(:second)

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^ctx.photo.uuid),
        set: [updated_at: long_ago]
      )

      send(view.pid, {:processed, ctx.photo.uuid})
      _ = render(view)
      assert render(view) =~ "Taking long? Start again"

      before = Storage.get_file(ctx.photo.uuid).edit_revision
      view |> element("button", "Start again") |> render_click()
      assert Storage.get_file(ctx.photo.uuid).edit_revision == before + 1
    end

    test "a refused save explains itself and keeps the draft", ctx do
      view = open(ctx.photo, user: ctx.owner)
      render_change(form(view), %{"edit" => crop_fields(0, 0, 50, 100)})

      {:ok, _} =
        Annotations.create(%{
          file_uuid: ctx.photo.uuid,
          kind: "rectangle",
          geometry: %{"x" => 0.1, "y" => 0.1, "w" => 0.2, "h" => 0.2}
        })

      html =
        view
        |> form()
        |> render_submit(%{"intent" => "save", "edit" => crop_fields(0, 0, 50, 100)})

      assert html =~ "Save a copy instead."
      assert html =~ "left: 0%; top: 0%; width: 50%; height: 100%;", "the crop is still there"
      assert Storage.get_file(ctx.photo.uuid).edits == nil
    end

    test "save as copy queues a copy and says so", ctx do
      view = open(ctx.photo, user: ctx.owner)

      html =
        view
        |> form()
        |> render_submit(%{"intent" => "copy", "edit" => %{"brightness" => "10"}})

      assert html =~ "A copy is being made."
      assert Storage.get_file(ctx.photo.uuid).edits == nil
    end
  end
end
