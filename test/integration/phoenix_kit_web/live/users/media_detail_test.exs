defmodule PhoenixKitWeb.Live.Users.MediaDetailTest do
  @moduledoc """
  The media detail page's image editing: the "Edit image" button swaps the
  canvas for the editor, and storage events keep the page current.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp image!(user, mime \\ "image/jpeg") do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "photo_#{n}.jpg",
        file_name: "photo_#{n}.jpg",
        mime_type: mime,
        file_type: "image",
        ext: "jpg",
        file_checksum: "sha256:detail-#{n}",
        user_file_checksum: "user-sha256:detail-#{n}",
        size: 1024,
        width: 800,
        height: 600,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, _} =
      Repo.insert(%Storage.FileInstance{
        file_uuid: file.uuid,
        variant_name: "original",
        file_name: "photo_#{n}.jpg",
        mime_type: mime,
        ext: "jpg",
        checksum: "sha256:detail-#{n}",
        size: 1024,
        width: 800,
        height: 600,
        processing_status: "completed"
      })

    file
  end

  defp path(file, query \\ ""), do: Routes.path("/admin/media/#{file.uuid}") <> query

  test "Edit image swaps the canvas for the editor, and back", %{conn: conn, user: user} do
    file = image!(user)
    {:ok, view, html} = live(conn, path(file))

    assert html =~ "media-detail-canvas-#{file.uuid}"
    refute html =~ "media-detail-image-editor"

    html = view |> element("button[phx-click=open_image_editor]") |> render_click()
    assert html =~ ~s(id="media-detail-image-editor-#{file.uuid}-form")
    refute html =~ "media-detail-canvas-#{file.uuid}"
    refute html =~ "Delete File", "the editor has the whole row"

    html = view |> element("button[aria-label=Close]") |> render_click()
    assert html =~ "media-detail-canvas-#{file.uuid}"
    refute html =~ "media-detail-image-editor"
  end

  test "?edit=image opens the editor directly", %{conn: conn, user: user} do
    file = image!(user)
    {:ok, _view, html} = live(conn, path(file, "?edit=image"))

    assert html =~ ~s(id="media-detail-image-editor-#{file.uuid}-form")
  end

  test "an image that cannot be edited offers no editor", %{conn: conn, user: user} do
    gif = image!(user, "image/gif")
    {:ok, _view, html} = live(conn, path(gif, "?edit=image"))

    refute html =~ "open_image_editor"
    refute html =~ "media-detail-image-editor"
    assert html =~ "media-detail-canvas-#{gif.uuid}"
  end

  test "a processed file shows its new state, in the page and the editor",
       %{conn: conn, user: user} do
    file = image!(user)
    {:ok, view, _html} = live(conn, path(file, "?edit=image"))

    Repo.update_all(
      from(f in StorageFile, where: f.uuid == ^file.uuid),
      set: [edit_state: "failed", edits: %{"rotate" => 90}, edit_revision: 1]
    )

    send(view.pid, {:phoenix_kit_file_processed, file.uuid})
    assert render(view) =~ "The edit could not be applied."

    # The info panel (hidden while editing) says so too.
    html = view |> element("button[aria-label=Close]") |> render_click()
    assert html =~ "Edit failed"

    # Another file's event changes nothing here.
    send(view.pid, {:phoenix_kit_file_processed, Ecto.UUID.generate()})
    assert render(view) =~ "Edit failed"
  end

  test "an edit remounts the canvas with the new original", %{conn: conn, user: user} do
    file = image!(user)
    {:ok, view, html} = live(conn, path(file))
    [before] = Regex.run(~r/id="(media-detail-canvas-[^"]+)"/, html, capture: :all_but_first)

    Repo.update_all(
      from(i in Storage.FileInstance, where: i.file_uuid == ^file.uuid),
      set: [checksum: "0123456789abcdef-edited"]
    )

    send(view.pid, {:phoenix_kit_file_processed, file.uuid})
    html = render(view)

    [now] = Regex.run(~r/id="(media-detail-canvas-[^"]+)"/, html, capture: :all_but_first)
    refute now == before
    assert now =~ "0123456789abcdef"
  end
end
