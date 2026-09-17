defmodule PhoenixKit.Modules.Storage.ImageProcessor do
  @moduledoc """
  ImageMagick-based image processing module.

  Handles image operations using ImageMagick command-line tools:
  - `identify` - Extract image metadata (dimensions, format)
  - `convert`/`magick` - Resize and format conversion

  This replaces Vix with ImageMagick, which is more widely trusted
  and has better long-term support.
  """

  require Logger

  alias PhoenixKit.Modules.Storage.ImageEdit

  @doc """
  Get the width of an image file using ImageMagick identify.

  Returns the width in pixels or nil if extraction fails.
  """
  def get_width(file_path) do
    case extract_dimensions(file_path) do
      {:ok, {width, _height}} -> width
      {:error, _reason} -> nil
    end
  end

  @doc """
  Get the height of an image file using ImageMagick identify.

  Returns the height in pixels or nil if extraction fails.
  """
  def get_height(file_path) do
    case extract_dimensions(file_path) do
      {:ok, {_width, height}} -> height
      {:error, _reason} -> nil
    end
  end

  @doc """
  Extract both width and height from an image file.

  Uses ImageMagick's `identify` command to extract image dimensions.

  Returns:
  - `{:ok, {width, height}}` - Dimensions in pixels
  - `{:error, reason}` - If extraction fails
  """
  def extract_dimensions(file_path) do
    case System.cmd("identify", ["-format", "%wx%h", file_path], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(String.trim(output), "x") do
          [width_str, height_str] ->
            case {Integer.parse(width_str), Integer.parse(height_str)} do
              {{width, ""}, {height, ""}} ->
                {:ok, {width, height}}

              _ ->
                {:error, "Failed to parse dimensions: #{output}"}
            end

          _ ->
            {:error, "Invalid dimension format: #{output}"}
        end

      {output, exit_code} ->
        {:error, "identify failed with exit code #{exit_code}: #{output}"}
    end
  rescue
    e ->
      {:error, "Failed to extract dimensions: #{inspect(e)}"}
  end

  @doc """
  Resize an image to fit within specified dimensions.

  Maintains aspect ratio by scaling to fit within bounds.
  Optionally converts format based on output_format parameter.

  Parameters:
  - `input_path` - Path to input image file
  - `output_path` - Path to save resized image
  - `width` - Target width (nil to use original)
  - `height` - Target height (nil to use original)
  - `opts` - Additional options
    - `:quality` - JPEG quality 1-100 (default: 85)
    - `:format` - Output format override (jpg, png, webp, etc)

  Returns:
  - `{:ok, output_path}` - Success
  - `{:error, reason}` - If resize fails
  """
  def resize(input_path, output_path, width, height, opts \\ []) do
    quality = Keyword.get(opts, :quality, 85)
    format = Keyword.get(opts, :format, nil)

    # Extract current dimensions
    case extract_dimensions(input_path) do
      {:ok, {current_width, current_height}} ->
        # Calculate resize parameters
        resize_spec = calculate_resize_spec(current_width, current_height, width, height)

        # Build ImageMagick convert command
        args = build_convert_args(input_path, output_path, resize_spec, quality, format)

        Logger.info(
          "Resizing image: #{input_path} -> #{output_path}, resize spec: #{resize_spec}"
        )

        case System.cmd("convert", args, stderr_to_stdout: true) do
          {_output, 0} ->
            Logger.info("Successfully resized image to #{output_path}")
            {:ok, output_path}

          {output, exit_code} ->
            Logger.error("convert failed with exit code #{exit_code}: #{output}")
            {:error, "ImageMagick convert failed: #{output}"}
        end

      {:error, reason} ->
        {:error, "Failed to extract image dimensions: #{reason}"}
    end
  rescue
    e ->
      Logger.error("Image resize failed: #{inspect(e)}")
      {:error, "Image resize failed: #{inspect(e)}"}
  end

  @doc """
  Resize and center-crop an image to exact dimensions.

  Zooms into the image to fill the target dimensions completely, then
  center-crops to extract the exact target size. No padding borders - the
  entire output is filled with the image content.

  This is ideal for thumbnails where you want perfect squares (e.g., 150x150)
  with the image zoomed in and centered, no white/black borders.

  The algorithm:
  1. Resizes image to fill the target box (scales to cover both dimensions)
  2. Centers the image using gravity
  3. Crops from center to exact target dimensions

  Parameters:
  - `input_path` - Path to input image file
  - `output_path` - Path to save cropped image
  - `width` - Target width (required)
  - `height` - Target height (required)
  - `opts` - Additional options
    - `:quality` - JPEG quality 1-100 (default: 85)
    - `:format` - Output format override (jpg, png, webp, etc)
    - `:background` - Background color (rarely used, default: "white")

  Returns:
  - `{:ok, output_path}` - Success
  - `{:error, reason}` - If processing fails
  """
  def resize_and_crop_center(input_path, output_path, width, height, opts \\ []) do
    quality = Keyword.get(opts, :quality, 85)
    format = Keyword.get(opts, :format, nil)
    alpha? = has_alpha_channel?(input_path)

    background =
      if Keyword.has_key?(opts, :background) do
        Keyword.get(opts, :background, "white")
      else
        if alpha?, do: "none", else: "white"
      end

    format =
      if format == "jpg" and alpha? do
        Logger.warning(
          "Image #{input_path} has alpha channel but format is jpg — overriding to webp to preserve transparency"
        )

        "webp"
      else
        format
      end

    if is_nil(width) or is_nil(height) do
      {:error, "Both width and height are required for center-crop resizing"}
    else
      Logger.info(
        "Center-cropping image: #{input_path} -> #{output_path}, target: #{width}x#{height}"
      )

      # Build ImageMagick convert command for center-crop
      args =
        build_center_crop_args(
          input_path,
          output_path,
          width,
          height,
          quality,
          format,
          background
        )

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("Successfully center-cropped image to #{output_path}")
          {:ok, output_path}

        {output, exit_code} ->
          Logger.error("convert failed with exit code #{exit_code}: #{output}")
          {:error, "ImageMagick convert failed: #{output}"}
      end
    end
  rescue
    e ->
      Logger.error("Image center-crop failed: #{inspect(e)}")
      {:error, "Image center-crop failed: #{inspect(e)}"}
  end

  # 40 megapixels — comfortably above any real camera or screenshot, far
  # below what it takes to hurt. `-resize` bounds the OUTPUT; the decoder
  # still rasterizes the input in full first, so a 5MB PNG declaring
  # 50000x50000 is ~10GB of RAM before a single pixel is written. The
  # `-limit` flags turn that into a failure rather than an outage, but
  # reading the header and refusing costs nothing and never starts it.
  @sanitize_max_pixels 40_000_000

  defp check_pixel_budget(width, height, max_pixels)
       when is_integer(width) and is_integer(height) and width * height > max_pixels,
       do: {:error, "image is too large"}

  defp check_pixel_budget(_width, _height, _max_pixels), do: :ok

  @doc """
  Re-encodes an image to known-good bytes, discarding everything else.

  For uploads from people you do not trust. The point is not to *inspect*
  the file — that is a losing game — but to stop serving the uploader's
  bytes at all: what ends up stored is this encoder's output, produced by
  decoding the input and writing a fresh image. A polyglot file (valid
  GIF, valid JavaScript), an EXIF payload, a trailing ZIP, an embedded
  colour profile — none of them survive being decoded to pixels and
  written out again.

  Also enforces a maximum edge length, because a 30000×30000 PNG is a
  decompression bomb whatever its byte size, and rejects anything
  ImageMagick cannot read as an image regardless of what the upload
  claimed to be.

  Returns `{:ok, output_path}` or `{:error, reason}`. Never raises.

  ## ⚠️ Nothing in core calls this yet

  It is a primitive, not a policy: no upload path in PhoenixKit routes
  through it, so adding it did not change what any existing endpoint
  stores. A caller that accepts untrusted uploads — a public portal
  submission, an avatar from an unauthenticated form — has to invoke it
  itself and store the OUTPUT path, discarding the original. Wiring it
  into `Storage.upload/*` wholesale is not a drop-in: it re-encodes, which
  is right for images from strangers and wrong for a designer uploading a
  master PNG they expect back byte-for-byte.

  ## Options

    * `:max_edge` — longest side in pixels (default 2500); larger images
      are scaled down, never up
    * `:quality` — output quality (default 82)
    * `:format` — output format (default "jpeg"; use "png" to keep
      transparency)

  ## Example

      ImageProcessor.sanitize(upload.path, dest, format: "png")
  """
  @spec sanitize(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def sanitize(input_path, output_path, opts \\ []) do
    max_edge = Keyword.get(opts, :max_edge, 2500)
    quality = Keyword.get(opts, :quality, 82)
    format = Keyword.get(opts, :format, "jpeg")

    max_pixels = Keyword.get(opts, :max_pixels, @sanitize_max_pixels)

    with {:ok, {width, height}} <- extract_dimensions(input_path),
         :ok <- check_pixel_budget(width, height, max_pixels),
         {:ok, detected} <- detect_format(input_path) do
      args =
        [
          # Resource ceilings, applied HERE rather than trusted to the
          # host's policy.xml. A decompression bomb is a small file that
          # decodes to gigabytes, and "the sysadmin configured ImageMagick
          # correctly" is not a control this code can rely on.
          "-limit",
          "memory",
          "256MiB",
          "-limit",
          "map",
          "512MiB",
          "-limit",
          "disk",
          "1GiB",
          "-limit",
          "time",
          "20"
        ] ++
          [
            # `[0]` takes the FIRST frame only: without it a multi-frame
            # GIF writes N output files, which is a cheap way to burn disk.
            # The format prefix pins how the bytes are decoded, so a file
            # can never be interpreted as a coder we did not allow.
            "#{detected}:#{input_path}[0]",
            "-auto-orient",
            # Strip metadata before anything else: EXIF, IPTC, XMP, colour
            # profiles, comments. GPS coordinates in a bug report screenshot
            # are a privacy leak the reporter did not intend.
            "-strip",
            "-alpha",
            if(format == "png", do: "on", else: "remove"),
            "-resize",
            "#{max_edge}x#{max_edge}>",
            "-quality",
            Integer.to_string(quality),
            "#{format}:#{output_path}"
          ]

      Logger.info(
        "Sanitizing #{detected} upload #{input_path} (#{width}x#{height}) -> #{output_path}"
      )

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, output_path}

        {output, exit_code} ->
          Logger.warning("Upload sanitize failed (#{exit_code}): #{output}")
          {:error, "could not process image"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Upload sanitize raised: #{Exception.message(e)}")
      {:error, "could not process image"}
  end

  # Private functions

  # What ImageMagick actually thinks this is, checked against a short
  # allowlist. The extension and the browser's content-type are both the
  # uploader's claims; this is the only reading that counts, and it does
  # not depend on the host having configured policy.xml.
  @sanitize_formats ~w(PNG JPEG JPG WEBP GIF)

  @doc """
  The size of the first frame after EXIF auto-orientation — the frame an
  edit's percentages refer to — and the number of frames in the file.

  Returns `{:ok, {width, height, frames}}` or `{:error, reason}`.
  """
  @spec oriented_info(String.t()) ::
          {:ok, {pos_integer(), pos_integer(), pos_integer()}} | {:error, String.t()}
  def oriented_info(file_path) do
    with {:ok, frames} <- frame_count(file_path),
         {output, 0} <-
           System.cmd(
             "convert",
             ["#{file_path}[0]", "-auto-orient", "-format", "%w %h", "info:"],
             stderr_to_stdout: true
           ),
         [w, h] <- output |> last_line() |> String.split(),
         {w, ""} <- Integer.parse(w),
         {h, ""} <- Integer.parse(h) do
      {:ok, {w, h, frames}}
    else
      {:error, _} = error -> error
      {output, _status} when is_binary(output) -> {:error, String.trim(output)}
      _ -> {:error, "could not read the image size"}
    end
  end

  defp frame_count(file_path) do
    case System.cmd("identify", ["-format", "%n\\n", file_path], stderr_to_stdout: true) do
      {output, 0} ->
        case output
             |> String.split("\n", trim: true)
             |> List.first()
             |> to_string()
             |> Integer.parse() do
          {n, _} when n > 0 -> {:ok, n}
          _ -> {:error, "could not count frames"}
        end

      {output, _} ->
        {:error, String.trim(output)}
    end
  end

  # IM7's `convert` prints a deprecation warning before the answer.
  defp last_line(output),
    do: output |> String.split("\n", trim: true) |> List.last() |> to_string()

  @doc """
  Renders an image edit (`PhoenixKit.Modules.Storage.ImageEdit`) of the
  first frame of `input_path` into `output_path`. `size` is the input's size
  after auto-orientation (`oriented_info/1`).
  """
  @spec render_edit(String.t(), String.t(), map() | nil, {pos_integer(), pos_integer()}) ::
          :ok | {:error, String.t()}
  def render_edit(input_path, output_path, edit, size) do
    args = ImageEdit.magick_args(edit, size, input_path, output_path)

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path), do: :ok, else: {:error, "no output was written"}

      {output, status} ->
        {:error, "ImageMagick exited with #{status}: #{String.trim(output)}"}
    end
  end

  defp detect_format(path) do
    case System.cmd("identify", ["-format", "%m", "#{path}[0]"], stderr_to_stdout: true) do
      {output, 0} ->
        format = output |> String.trim() |> String.upcase()

        if format in @sanitize_formats,
          do: {:ok, format},
          else: {:error, "unsupported image format"}

      _ ->
        {:error, "not a readable image"}
    end
  rescue
    _ -> {:error, "not a readable image"}
  end

  defp calculate_resize_spec(current_width, current_height, target_width, target_height) do
    case {target_width, target_height} do
      {w, h} when w != nil and h != nil ->
        # Both width and height specified - fit within bounds preserving aspect ratio
        # Use ImageMagick's extent notation: scale to fit, then extend to exact size if needed
        # The '>' suffix means only shrink, never enlarge
        "#{w}x#{h}>"

      {w, nil} when w != nil ->
        # Only width specified - maintain aspect ratio
        "#{w}x"

      {nil, h} when h != nil ->
        # Only height specified - maintain aspect ratio
        "x#{h}"

      _ ->
        # No dimensions - return original size
        "#{current_width}x#{current_height}"
    end
  end

  defp build_convert_args(input_path, output_path, resize_spec, quality, format) do
    args = [input_path]

    # Add resize operation
    args = args ++ ["-resize", resize_spec]

    # Add quality setting for JPEG (ImageMagick quality for lossy formats)
    args = args ++ ["-quality", to_string(quality)]

    # Add format conversion if specified
    args =
      if format do
        format_spec = "#{format}:#{output_path}"
        args ++ [format_spec]
      else
        args ++ [output_path]
      end

    args
  end

  defp build_center_crop_args(input_path, output_path, width, height, quality, format, background) do
    args = [input_path]

    # Set background color for padding/extension (rarely used with ^ resize)
    args = args ++ ["-background", background]

    # Resize to fill/cover the target dimensions (with the ^ flag)
    # The ^ flag means "resize to FILL the box" - scales up to ensure both dimensions
    # are at least the target size, creating overflow that gets cropped
    resize_spec = "#{width}x#{height}^"
    args = args ++ ["-resize", resize_spec]

    # Use gravity center to position image at center before cropping
    args = args ++ ["-gravity", "center"]

    # Crop to exact dimensions from the centered position
    args = args ++ ["-extent", "#{width}x#{height}"]

    # Add quality setting for JPEG (ImageMagick quality for lossy formats)
    args = args ++ ["-quality", to_string(quality)]

    # Add format conversion if specified
    args =
      if format do
        format_spec = "#{format}:#{output_path}"
        args ++ [format_spec]
      else
        args ++ [output_path]
      end

    args
  end

  defp has_alpha_channel?(file_path) do
    case System.cmd("identify", ["-format", "%[channels]", file_path], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(String.trim(output), "a")
      _ -> false
    end
  rescue
    _ -> false
  end
end
