defmodule PhoenixKit.Modules.Storage.AnnotationThumbnail do
  @moduledoc """
  Bakes Etcher annotation shapes into a single PNG thumbnail variant.

  A file with annotations gets one extra variant — `"thumbnail_annotated"` — a
  small square PNG with the shapes drawn on top (via ImageMagick `convert
  -draw`). The media browser grid uses it instead of the plain thumbnail, so the
  markup is visible without rendering shapes live for every viewer.

  It's a single deterministic variant slot: each regeneration overwrites it (no
  history piles up). When the last annotation is removed, the variant is dropped
  and the grid falls back to the plain thumbnail.

  Shapes are stored in image-pixel coordinates, so they're drawn at original
  scale on the original image (the geometry → draw mapping lives in
  `Etcher.Raster`, which owns the shape format), then the whole thing is resized
  + center-cropped to the thumbnail square — the crop clips edge shapes exactly
  like the grid.

  Regeneration is meant to run in the background (see `AnnotationThumbnailJob`),
  debounced so a flurry of edits collapses into one render.
  """

  # `Etcher.Raster` (the server-side shape renderer) ships in newer Etcher; tolerate
  # older versions at compile time and degrade gracefully at runtime.
  @compile {:no_warn_undefined, Etcher.Raster}

  require Logger

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Settings

  @variant_name "thumbnail_annotated"
  # Square size of the baked thumbnail (px).
  @size 400
  # Media setting gating the whole feature (baking + display). Off by default.
  @setting_key "storage_annotated_thumbnails_enabled"

  @doc "The variant name this module produces."
  def variant_name, do: @variant_name

  @doc """
  Whether baked annotated thumbnails are enabled (media setting; default `false`).

  Gates generation and display — see the media settings page, "Media
  Configuration" section.
  """
  def enabled?, do: Settings.get_boolean_setting(@setting_key, false)

  @doc """
  Regenerate (or remove) the baked annotated thumbnail for `file_uuid`.

  Returns `{:ok, instance}` when (re)generated, `{:ok, :removed}` when there's
  nothing to draw, or `{:error, reason}`.
  """
  def refresh(file_uuid) when is_binary(file_uuid) do
    case Storage.get_file(file_uuid) do
      %Storage.File{file_type: "image"} = file ->
        if enabled?() do
          annotations = Annotations.list_for_file(file_uuid)

          case draw_args(annotations, base_dimension(file)) do
            [] ->
              remove_variant(file)
              {:ok, :removed}

            draw_args ->
              generate(file, draw_args)
          end
        else
          # Feature toggled off — drop any stale baked variant.
          remove_variant(file)
          {:ok, :removed}
        end

      _ ->
        # Non-image (or missing) file — nothing to annotate.
        {:ok, :removed}
    end
  rescue
    e ->
      Logger.warning("AnnotationThumbnail.refresh failed for #{file_uuid}: #{inspect(e)}")
      {:error, :exception}
  end

  defp generate(file, draw_args) do
    with {:ok, original_path, file, source} <- Storage.retrieve_original(file.uuid),
         output <- temp_png(),
         :ok <- run_convert(original_path, output, draw_args) do
      # Drop any existing instance first so a fresh one is created with the new
      # checksum (create_variant_instance returns the existing row otherwise).
      remove_variant(file)

      result =
        VariantGenerator.store_prepared_variant(file, @variant_name, output, "png", "image/png",
          source_key: source.file_name
        )

      File.rm(original_path)
      result
    else
      error ->
        Logger.warning("AnnotationThumbnail.generate failed for #{file.uuid}: #{inspect(error)}")
        {:error, :generate_failed}
    end
  end

  defp run_convert(input_path, output_path, draw_args) do
    # `draw_args` already carries `-fill none` + the per-shape `-stroke/-draw`
    # (from Etcher.Raster); we just splice it in before the resize/crop so shapes
    # are drawn in the source image's pixel space and scale with it.
    args =
      [input_path] ++
        draw_args ++
        ["-resize", "#{@size}x#{@size}^", "-gravity", "center", "-extent", "#{@size}x#{@size}"] ++
        ["png:#{output_path}"]

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "convert exited #{code}: #{out}"}
    end
  end

  # Etcher owns the geometry → draw mapping. Convert our `Annotation` structs to
  # the generic wire shape and hand them to `Etcher.Raster`, supplying the render
  # policy (stroke width scaled to the source image so it survives the
  # down-scale). Degrades to no overlay when the installed Etcher predates the
  # server renderer.
  defp draw_args(annotations, base_dim) do
    if Code.ensure_loaded?(Etcher.Raster) do
      annotations
      # `metadata` rides along for the label text: from etcher 0.12.1,
      # Raster draws a text/callout annotation's actual words
      # (`metadata.title`) instead of baking its bounding box — which on a
      # thumbnail looked like a mystery rectangle where a word should be.
      # Older Raster ignores the extra key and keeps the box fallback.
      |> Enum.map(fn a ->
        %{
          "kind" => a.kind,
          "geometry" => a.geometry,
          "style" => a.style,
          "metadata" => a.metadata
        }
      end)
      |> Etcher.Raster.to_draw_args(stroke_width: max(round(base_dim / 200), 3))
    else
      []
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp remove_variant(file) do
    case Storage.get_file_instance_by_name(file.uuid, @variant_name) do
      %Storage.FileInstance{} = instance -> Storage.delete_file_instance(instance)
      _ -> :ok
    end
  end

  defp base_dimension(file) do
    max(file.width || 0, file.height || 0)
    |> case do
      0 -> 1000
      dim -> dim
    end
  end

  defp temp_png do
    name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "phoenix_kit_annotated_#{name}.png")
  end
end
