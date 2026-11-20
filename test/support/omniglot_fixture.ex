defmodule OmniglotFixture do
  @moduledoc """
  A two-alphabet Omniglot dataset, written where a world can be pointed at it.

  The drawing is a 30 × 30 one-bit picture PIL wrote: white paper with a diagonal
  ink stroke from the sixth row down, two pixels wide. Its pen path is the same
  diagonal — the dataset records where the pen went, in coordinates whose `y`
  points up, so the file's numbers are negative where the picture's rows are not.
  """

  # PIL 12.3 wrote it: one bit a pixel, which is what a drawing in this dataset is.
  @drawing "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQAAAAATS5MPAAAATElEQVR4nHXNsQ2AMBBD0X+JlCoD" <>
             "ZIwswC4ZhILRGIGF4NDvoXmFZdmRcBeAby4Z0qVJlXJQiNPekilDujSpkPnskbC5t2TKMPv/fQGV" <>
             "LgyJGjSHIQAAAABJRU5ErkJggg=="

  @stroke """
  START
  10.0,-6.0,0
  11.0,-7.0,60
  12.0,-8.0,120
  13.0,-9.0,180
  14.0,-10.0,240
  15.0,-11.0,300
  16.0,-12.0,360
  17.0,-13.0,420
  18.0,-14.0,480
  19.0,-15.0,540
  20.0,-16.0,600
  21.0,-17.0,660
  22.0,-18.0,720
  23.0,-19.0,780
  24.0,-20.0,840
  25.0,-21.0,900
  26.0,-22.0,960
  27.0,-23.0,1020
  BREAK
  """

  @doc """
  A directory holding `alphabets` (by name), each with three characters and one
  version of each of them, and its pen path.

  The dataset has 20 characters in an alphabet and 20 drawings of each; three is
  enough for a config that names three, which is what Monty's Omniglot configs
  do.
  """
  @spec write([String.t()]) :: Path.t()
  def write(alphabets \\ ["Alpha", "Beta"]) do
    path = Path.join(System.tmp_dir!(), "omniglot_#{System.unique_integer([:positive])}")

    for alphabet <- alphabets, character <- 1..3 do
      images = Path.join([path, "images_background", alphabet, character_directory(character)])
      strokes = Path.join([path, "strokes_background", alphabet, character_directory(character)])
      File.mkdir_p!(images)
      File.mkdir_p!(strokes)

      File.write!(Path.join(images, "0#{character}_01.png"), Base.decode64!(@drawing))
      File.write!(Path.join(strokes, "0#{character}_01.txt"), @stroke)
    end

    path
  end

  defp character_directory(character),
    do: "character#{String.pad_leading(to_string(character), 2, "0")}"

  @doc "Where a 10-pixel patch fits along this drawing's path, as the world counts it."
  @spec path() :: [[non_neg_integer()]]
  def path, do: for(k <- 5..9, do: [10 + k, 6 + k])
end
