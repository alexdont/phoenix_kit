defmodule PhoenixKit.Modules.Storage.ImageEditTest do
  @moduledoc """
  `ImageEdit` — what an edit is, and the ImageMagick arguments for it.

  The canonical form matters: it is stored on the file, compared to decide
  whether anything changed, and always applied to the unedited original.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.ImageEdit

  doctest ImageEdit

  describe "normalize/1" do
    test "accepts form input: string numbers, checkbox strings, position-keyed lists" do
      assert {:ok, edit} =
               ImageEdit.normalize(%{
                 "rotate" => "180",
                 "flip_v" => "on",
                 "flip_h" => "false",
                 "straighten" => "-3.25",
                 "brightness" => "12.4",
                 "redact" => %{
                   "1" => %{"x" => "50", "y" => "50", "w" => "10", "h" => "10", "style" => "fill"},
                   "0" => %{"x" => "0", "y" => "0", "w" => "10", "h" => "10"}
                 },
                 "crop" => %{"x" => "10", "y" => "0", "w" => "80", "h" => "100"}
               })

      assert edit == %{
               "rotate" => 180,
               "flip_v" => true,
               "straighten" => -3.3,
               "brightness" => 12,
               "redact" => [
                 %{"x" => +0.0, "y" => +0.0, "w" => 10.0, "h" => 10.0, "style" => "blur"},
                 %{"x" => 50.0, "y" => 50.0, "w" => 10.0, "h" => 10.0, "style" => "fill"}
               ],
               "crop" => %{"x" => 10.0, "y" => +0.0, "w" => 80.0, "h" => 100.0}
             }
    end

    test "clamps into range" do
      assert {:ok, edit} =
               ImageEdit.normalize(%{
                 straighten: 90,
                 contrast: -500,
                 crop: %{x: 90, y: -10, w: 50, h: 200}
               })

      assert edit["straighten"] == 45.0
      assert edit["contrast"] == -100
      assert edit["crop"] == %{"x" => 90.0, "y" => +0.0, "w" => 10.0, "h" => 100.0}
    end

    test "an edit that changes nothing is nil" do
      assert ImageEdit.normalize(%{}) == {:ok, nil}
      assert ImageEdit.normalize(nil) == {:ok, nil}

      assert ImageEdit.normalize(%{rotate: 360, straighten: "0", brightness: 0, flip_h: false}) ==
               {:ok, nil}
    end

    test "degenerate rectangles are dropped, not rendered as a 1px sliver" do
      assert {:ok, nil} =
               ImageEdit.normalize(%{
                 crop: %{x: 10, y: 10, w: 0.2, h: 50},
                 redact: [%{x: 1, y: 1, w: 0.1, h: 5}, %{x: "a", y: 1, w: 5, h: 5}, :nope]
               })
    end

    test "rejects what cannot be an edit" do
      assert ImageEdit.normalize(%{rotate: 45}) == {:error, :invalid_rotation}
      assert ImageEdit.normalize(%{rotate: "left"}) == {:error, :invalid_rotation}
      assert ImageEdit.normalize(%{redact: "everything"}) == {:error, :invalid_regions}

      too_many = for _ <- 1..51, do: %{x: 0, y: 0, w: 5, h: 5}
      assert ImageEdit.normalize(%{redact: too_many}) == {:error, :too_many_regions}
      assert ImageEdit.normalize("rotate") == {:error, :invalid_edit}
    end
  end

  test "geometric?/1 separates moving pixels from changing them" do
    refute ImageEdit.geometric?(nil)
    refute ImageEdit.geometric?(%{"brightness" => 10, "redact" => [%{}]})

    for key <- ~w(rotate flip_h flip_v straighten crop) do
      assert ImageEdit.geometric?(%{key => 1}), key
    end
  end

  describe "straighten_scale/3" do
    test "covers the frame in both directions" do
      # A 2:1 frame turned 45° either way needs the same, larger-than-one scale.
      expected = (2000 * :math.cos(:math.pi() / 4) + 1000 * :math.sin(:math.pi() / 4)) / 1000

      assert_in_delta ImageEdit.straighten_scale(2000, 1000, 45), expected, 1.0e-9
      assert_in_delta ImageEdit.straighten_scale(2000, 1000, -45), expected, 1.0e-9
      assert ImageEdit.straighten_scale(2000, 1000, -15) > 1
    end
  end

  describe "magick_args/4" do
    test "applies the steps in the fixed order, resetting the page after each geometry step" do
      edit = %{
        "rotate" => 90,
        "flip_h" => true,
        "straighten" => 5.0,
        "redact" => [%{"x" => 0.0, "y" => 0.0, "w" => 50.0, "h" => 50.0, "style" => "fill"}],
        "crop" => %{"x" => 25.0, "y" => 25.0, "w" => 50.0, "h" => 50.0},
        "brightness" => 10
      }

      args = ImageEdit.magick_args(edit, {400, 200}, "in.jpg", "out.jpg")

      # The last "-crop" is the crop step; each redaction crops its own clone first.
      order =
        Enum.map(
          ~w(-auto-orient -rotate -flop -distort -composite -crop -brightness-contrast +profile),
          &last_index(args, &1)
        )

      assert order == Enum.sort(order)
      assert Enum.take(args, 2) == ["-respect-parentheses", "in.jpg[0]"]
      assert List.last(args) == "out.jpg"

      # The frame is 200x400 after the quarter turn, so percentages map onto it.
      # The redaction is widened by 2 px on each side, inside the frame.
      assert "104x204+0+0" in args
      assert "100x200+50+100" in args
      assert Enum.at(args, index(args, "-rotate") + 2) == "+repage"
      assert Enum.at(args, index(args, "-distort") + 3) == "+repage"
    end

    test "keeps the ICC profile and drops the rest of the metadata" do
      args = ImageEdit.magick_args(nil, {10, 10}, "a.png", "b.png")
      assert ["+profile", "!icc,*"] == Enum.slice(args, index(args, "+profile"), 2)
    end

    test "redaction keeps cells large in absolute pixels" do
      region = fn w, h -> %{"x" => 0.0, "y" => 0.0, "w" => w, "h" => h, "style" => "pixelate"} end

      args = fn region, size -> ImageEdit.magick_args(%{"redact" => [region]}, size, "i", "o") end

      # 20x20 px (24 with the outset): under two 32 px cells, one flat colour.
      assert "1x1!" in args.(region.(20.0, 20.0), {100, 100})

      # 4000x2000 px: at most 12 cells on the long side (334 px each),
      # however large the region — a plate this size shrunk by a ratio alone
      # would still be readable.
      assert "11x5!" in args.(region.(100.0, 100.0), {4000, 2000})
    end
  end

  describe "turn/2 and mirror/2" do
    # Where a point of the source (fractions 0..1) ends up in the frame, for
    # the quarter turn and the mirrors of `edit` — the order the pipeline
    # applies them in (rotate, then mirror).
    defp forward(edit, {u, v}) do
      {x, y} =
        case Map.get(edit, "rotate", 0) do
          0 -> {u, v}
          90 -> {1 - v, u}
          180 -> {1 - u, 1 - v}
          270 -> {v, 1 - u}
        end

      x = if edit["flip_h"], do: 1 - x, else: x
      y = if edit["flip_v"], do: 1 - y, else: y
      {x, y}
    end

    # The inverse: which source point a frame point shows.
    defp backward(edit, {x, y}) do
      x = if edit["flip_h"], do: 1 - x, else: x
      y = if edit["flip_v"], do: 1 - y, else: y

      case Map.get(edit, "rotate", 0) do
        0 -> {x, y}
        90 -> {y, 1 - x}
        180 -> {1 - x, 1 - y}
        270 -> {1 - y, x}
      end
    end

    # The source pixels a rectangle covers, as a set of rounded corners.
    defp covered(edit, %{"x" => x, "y" => y, "w" => w, "h" => h}) do
      for cx <- [x, x + w], cy <- [y, y + h], into: MapSet.new() do
        {u, v} = backward(edit, {cx / 100, cy / 100})
        {Float.round(u * 1.0, 6), Float.round(v * 1.0, 6)}
      end
    end

    defp edits do
      rect = %{"x" => 10.0, "y" => 20.0, "w" => 30.0, "h" => 15.0}
      area = %{"x" => 55.0, "y" => 5.0, "w" => 20.0, "h" => 40.0, "style" => "fill"}

      for rotate <- [0, 90, 180, 270], flip_h <- [false, true], flip_v <- [false, true] do
        %{
          "rotate" => rotate,
          "flip_h" => flip_h,
          "flip_v" => flip_v,
          "crop" => rect,
          "redact" => [area]
        }
        |> Map.reject(fn {_k, v} -> v in [0, false] end)
      end
    end

    defp operations do
      [
        {&ImageEdit.turn(&1, :right), &__MODULE__.turned_right/1},
        {&ImageEdit.turn(&1, :left), &__MODULE__.turned_left/1},
        {&ImageEdit.mirror(&1, :horizontal), &__MODULE__.mirrored_h/1},
        {&ImageEdit.mirror(&1, :vertical), &__MODULE__.mirrored_v/1}
      ]
    end

    # What the shown image does, as a map of frame points.
    def turned_right({x, y}), do: {1 - y, x}
    def turned_left({x, y}), do: {y, 1 - x}
    def mirrored_h({x, y}), do: {1 - x, y}
    def mirrored_v({x, y}), do: {x, 1 - y}

    test "the shown image turns and mirrors as asked, whatever is already applied" do
      for edit <- edits(),
          {operation, expected} <- operations(),
          point <- [{0.1, 0.3}, {0.8, 0.6}] do
        changed = operation.(edit)
        {x, y} = expected.(forward(edit, point))
        {nx, ny} = forward(changed, point)

        assert_in_delta nx, x, 1.0e-9, "#{inspect(edit)} -> #{inspect(changed)}"
        assert_in_delta ny, y, 1.0e-9, "#{inspect(edit)} -> #{inspect(changed)}"
      end
    end

    test "the crop and the areas stay on the pixels they covered" do
      for edit <- edits(), {operation, _} <- operations() do
        changed = operation.(edit)

        assert covered(changed, changed["crop"]) == covered(edit, edit["crop"])
        [before] = edit["redact"]
        [after_] = changed["redact"]
        assert covered(changed, after_) == covered(edit, before)
        assert after_["style"] == "fill"
      end
    end

    test "a straightening turns with a mirror, not with a turn" do
      edit = %{"straighten" => 3.5}

      assert ImageEdit.turn(edit, :right)["straighten"] == 3.5
      assert ImageEdit.mirror(edit, :vertical)["straighten"] == -3.5
    end

    test "four turns, or two mirrors, change nothing" do
      for edit <- edits() do
        assert edit
               |> ImageEdit.turn(:right)
               |> ImageEdit.turn(:right)
               |> ImageEdit.turn(:right)
               |> ImageEdit.turn(:right) == edit

        assert edit |> ImageEdit.mirror(:horizontal) |> ImageEdit.mirror(:horizontal) == edit
        assert edit |> ImageEdit.turn(:left) |> ImageEdit.turn(:right) == edit
      end
    end

    test "results are canonical: what normalize/1 would make of them" do
      for edit <- edits(), {operation, _} <- operations() do
        changed = operation.(edit)
        assert {:ok, ^changed} = ImageEdit.normalize(changed)
      end
    end

    test "centred_crop/3 is the largest centred crop of that shape in the turned frame" do
      assert ImageEdit.centred_crop(%{"rotate" => 90}, {1, 1}, {400, 200}) ==
               %{"x" => 0.0, "y" => 25.0, "w" => 100.0, "h" => 50.0}

      crop = ImageEdit.centred_crop(%{}, {16, 9}, {1000, 1000})
      assert_in_delta crop["w"] * 1000 / (crop["h"] * 1000), 16 / 9, 0.001
      assert crop["x"] == 0.0
    end
  end

  describe "geometry/1" do
    test "is what moves pixels, nothing else" do
      assert ImageEdit.geometry(nil) == %{}

      assert ImageEdit.geometry(%{"rotate" => 90, "brightness" => 10, "redact" => []}) ==
               %{"rotate" => 90}
    end
  end

  defp index(list, item), do: Enum.find_index(list, &(&1 == item))

  defp last_index(list, item),
    do: length(list) - 1 - Enum.find_index(Enum.reverse(list), &(&1 == item))
end
