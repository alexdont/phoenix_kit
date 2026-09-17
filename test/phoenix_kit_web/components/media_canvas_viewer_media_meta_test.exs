defmodule PhoenixKitWeb.Components.MediaCanvasViewerMediaMetaTest do
  @moduledoc """
  The viewer sidebar's "Title & description" section: the file's own
  words about itself, collapsible behind a chevron, editable in the
  contexts that can already reach the metadata editor (details_path /
  edit_target hosts). Writes go into the file's metadata JSONB under
  the same keys the admin detail page's editor uses — merged, never
  replacing, so rotation/tags survive a title edit.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, media_details_open: false}, assigns)
    }
  end

  describe "saving (DB)" do
    setup do
      {:ok, file} =
        %Storage.File{}
        |> Storage.File.changeset(%{
          original_file_name: "meta_test.png",
          file_name: "meta_test.png",
          file_path: "aa/bb/meta_test",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          size: 10,
          status: "active",
          # The keys a title edit must NOT disturb.
          metadata: %{"rotation" => 90, "tags" => ["a", "b"]}
        })
        |> Repo.insert()

      %{file: file}
    end

    test "merges title and description into the row's metadata", %{file: file} do
      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "  A title  ", "description" => "Words."},
          socket
        )

      assert socket.assigns.media_meta == %{title: "A title", description: "Words."}
      assert socket.assigns.media_meta_status == :saved

      row = Storage.get_file(file.uuid)
      assert row.metadata["title"] == "A title"
      assert row.metadata["description"] == "Words."
      assert row.metadata["rotation"] == 90, "a title edit must never eat the rotation"
      assert row.metadata["tags"] == ["a", "b"], "…or the tags"
    end

    test "a vanished row reports an error instead of raising", %{file: file} do
      Repo.delete!(file)

      socket =
        socket_with(%{
          id: "mcv-test",
          file: %{file_uuid: file.uuid},
          media_meta: %{title: "", description: ""},
          media_meta_status: nil
        })

      {:noreply, socket} =
        MediaCanvasViewer.handle_event("save_media_details", %{"title" => "x"}, socket)

      assert socket.assigns.media_meta_status == :error
    end
  end
end

defmodule PhoenixKitWeb.Components.MediaCanvasViewerMediaMetaUnitTest do
  @moduledoc "The DB-less half: the chevron toggle and the status clear."

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, media_details_open: false}, assigns)
    }
  end

  test "the chevron toggles the section" do
    {:noreply, socket} =
      MediaCanvasViewer.handle_event("toggle_media_details", %{}, socket_with(%{}))

    assert socket.assigns.media_details_open

    {:noreply, socket} = MediaCanvasViewer.handle_event("toggle_media_details", %{}, socket)
    refute socket.assigns.media_details_open
  end

  test "the transient save status clears" do
    {:ok, socket} =
      MediaCanvasViewer.update(
        %{action: :clear_media_meta_status},
        socket_with(%{media_meta_status: :saved})
      )

    assert socket.assigns.media_meta_status == nil
  end
end
