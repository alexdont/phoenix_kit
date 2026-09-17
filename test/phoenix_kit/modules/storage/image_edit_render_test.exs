defmodule PhoenixKit.Modules.Storage.ImageEditRenderTest do
  @moduledoc """
  `ImageProcessor.render_edit/4` against real ImageMagick: the pixels end up
  where the edit says, a redacted area really loses its detail, EXIF
  orientation is honoured and metadata does not survive.

  Skipped when ImageMagick isn't installed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.ImageEdit
  alias PhoenixKit.Modules.Storage.ImageProcessor

  @moduletag :tmp_dir
  @moduletag :integration

  # ExUnit cannot skip from `setup` (a `skip:` it returns is only context), so
  # the ImageMagick check is a module tag. `convert`/`identify` are what
  # `ImageProcessor` runs — ImageMagick 6 has no `magick` binary.
  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  setup do
    if imagemagick?(), do: :ok, else: {:ok, skip: true}
  end

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp magick!(args) do
    {out, 0} = System.cmd("convert", args, stderr_to_stdout: true)
    out
  end

  # Left half red, right half blue, 200x100.
  defp halves(dir, name \\ "halves.png") do
    path = Path.join(dir, name)
    magick!(["-size", "100x100", "xc:red", "-size", "100x100", "xc:blue", "+append", path])
    path
  end

  # Alternating black and white pixels: all detail, one average colour.
  defp checker(dir) do
    path = Path.join(dir, "checker.png")
    magick!(["-size", "200x200", "pattern:gray50", path])
    path
  end

  # A JPEG whose pixels are stored sideways, with an EXIF orientation of 6
  # ("rotate 90° clockwise to view"). ImageMagick will not write the tag into
  # a file that has no EXIF block, so the block is built here: a one-entry
  # big-endian TIFF directory in an APP1 segment right after SOI.
  defp sideways_jpeg(dir) do
    plain = Path.join(dir, "plain.jpg")
    magick!([halves(dir), plain])
    <<0xFF, 0xD8, rest::binary>> = File.read!(plain)

    tiff =
      "MM" <> <<42::16, 8::32, 1::16>> <> <<0x0112::16, 3::16, 1::32, 6::16, 0::16>> <> <<0::32>>

    payload = "Exif" <> <<0, 0>> <> tiff
    app1 = <<0xFF, 0xE1, byte_size(payload) + 2::16>> <> payload

    path = Path.join(dir, "sideways.jpg")
    File.write!(path, <<0xFF, 0xD8>> <> app1 <> rest)
    path
  end

  defp pixel(path, x, y) do
    magick!([path, "-format", "%[pixel:p{#{x},#{y}}]", "info:"])
    |> String.split("\n", trim: true)
    |> List.last()
  end

  # Standard deviation of a region: 0 for a flat area, high for detail.
  defp spread(path, geometry) do
    magick!([path, "-crop", geometry, "+repage", "-format", "%[fx:standard_deviation]", "info:"])
    |> String.split("\n", trim: true)
    |> List.last()
    |> Float.parse()
    |> elem(0)
  end

  defp render!(src, dir, params, out_name \\ "out.png") do
    {:ok, edit} = ImageEdit.normalize(params)
    {:ok, {w, h, 1}} = ImageProcessor.oriented_info(src)
    out = Path.join(dir, out_name)
    assert :ok = ImageProcessor.render_edit(src, out, edit, {w, h})
    {:ok, {ow, oh, _}} = ImageProcessor.oriented_info(out)
    assert {ow, oh} == ImageEdit.output_size(edit, {w, h})
    out
  end

  # JPEG shifts pure colours by a few levels.
  defp red?(color), do: match?([r, g, b | _] when r > 200 and g < 60 and b < 60, rgb(color))
  defp blue?(color), do: match?([r, g, b | _] when r < 60 and g < 60 and b > 200, rgb(color))

  defp rgb(color) do
    ~r/[\d.]+/
    |> Regex.scan(color)
    |> List.flatten()
    |> Enum.map(&(&1 |> Float.parse() |> elem(0)))
  end

  test "a quarter turn clockwise puts the left half on top", %{tmp_dir: dir} do
    out = render!(halves(dir), dir, %{rotate: 90})

    assert red?(pixel(out, 50, 20))
    assert blue?(pixel(out, 50, 180))
  end

  test "flipping left-right swaps the halves", %{tmp_dir: dir} do
    out = render!(halves(dir), dir, %{flip_h: true})

    assert blue?(pixel(out, 10, 50))
    assert red?(pixel(out, 190, 50))
  end

  test "cropping keeps exactly the chosen percentage", %{tmp_dir: dir} do
    out = render!(halves(dir), dir, %{crop: %{x: 50, y: 0, w: 50, h: 50}})

    assert {:ok, {100, 50, 1}} = ImageProcessor.oriented_info(out)
    assert blue?(pixel(out, 0, 0))
  end

  test "straightening keeps the frame and shows no blank corner", %{tmp_dir: dir} do
    src = Path.join(dir, "green.png")
    magick!(["-size", "300x150", "xc:lime", src])

    for degrees <- [-15, 30] do
      out = render!(src, dir, %{straighten: degrees}, "s#{degrees}.png")

      for {x, y} <- [{0, 0}, {299, 0}, {0, 149}, {299, 149}] do
        assert pixel(out, x, y) =~ "0,255,0", "corner #{x},#{y} at #{degrees}°"
      end
    end
  end

  test "every redaction style removes the detail of its region", %{tmp_dir: dir} do
    src = checker(dir)
    assert spread(src, "100x100+0+0") > 0.4

    for style <- ~w(blur pixelate fill) do
      out =
        render!(src, dir, %{redact: [%{x: 0, y: 0, w: 50, h: 50, style: style}]}, "#{style}.png")

      assert spread(out, "100x100+0+0") < 0.05, style
      assert spread(out, "100x100+100+100") > 0.3, "#{style} left the rest alone"
    end
  end

  test "a small redacted region is hidden too", %{tmp_dir: dir} do
    out =
      render!(checker(dir), dir, %{redact: [%{x: 10, y: 10, w: 10, h: 10}]}, "small.png")

    assert spread(out, "20x20+20+20") < 0.05
  end

  test "EXIF orientation is applied before the edit", %{tmp_dir: dir} do
    src = sideways_jpeg(dir)
    assert magick!([src, "-format", "%[orientation]", "info:"]) =~ "RightTop"
    assert {:ok, {100, 200, 1}} = ImageProcessor.oriented_info(src)

    # Viewed upright, the red half is on top; the edit starts from that view.
    out = render!(src, dir, %{brightness: 1}, "oriented.png")
    assert {:ok, {100, 200, 1}} = ImageProcessor.oriented_info(out)
    assert red?(pixel(out, 50, 20))
  end

  test "EXIF metadata does not survive the edit", %{tmp_dir: dir} do
    src = Path.join(dir, "exif.jpg")
    magick!([halves(dir), "-set", "comment", "SECRET-COMMENT", src])
    assert magick!([src, "-format", "%c", "info:"]) =~ "SECRET-COMMENT"

    out = render!(src, dir, %{brightness: 5}, "clean.jpg")
    refute magick!([out, "-format", "%c", "info:"]) =~ "SECRET-COMMENT"
  end

  test "an animated image reports its frames, so callers can refuse it", %{tmp_dir: dir} do
    gif = Path.join(dir, "anim.gif")
    magick!(["-size", "10x10", "xc:red", "xc:blue", "-loop", "0", gif])

    assert {:ok, {10, 10, 2}} = ImageProcessor.oriented_info(gif)
  end

  test "a file that is not an image is an error, not a crash", %{tmp_dir: dir} do
    bogus = Path.join(dir, "bogus.png")
    File.write!(bogus, "not an image")

    assert {:error, _} = ImageProcessor.oriented_info(bogus)
    assert {:error, _} = ImageProcessor.render_edit(bogus, Path.join(dir, "x.png"), nil, {1, 1})
  end
end
