defmodule ExTbpMonty.Objaverse.CorpusTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Objaverse.Corpus

  # The import's own row, cut down to what the comparability rule reads: what
  # the world will see of one object, in metres.
  defp row(id, {x, y, z}), do: %{id: id, size: {x, y, z}}

  describe "a corpus the patch can treat alike" do
    test "objects of one footprint are comparable" do
      report =
        Corpus.report([
          row("plate", {0.06, 0.05, 0.10}),
          row("mug", {0.05, 0.06, 0.10})
        ])

      assert Corpus.comparable?(report)
      assert report.outliers == []
      assert report.spread |> Float.round(1) == 1.0
    end

    # The patch walks the horizontal plane, so a tall thin object with the same
    # footprint is the same amount of object to walk.
    test "a taller object with the same footprint is not an outlier" do
      report = Corpus.report([row("short", {0.06, 0.06, 0.04}), row("tall", {0.06, 0.06, 0.12})])

      assert Corpus.comparable?(report)
    end

    test "one object is comparable with itself" do
      assert Corpus.comparable?(Corpus.report([row("only", {0.23, 0.17, 0.09})]))
    end
  end

  describe "a corpus that is not" do
    # Measured on the dogs: five objects normalised to one height, and the
    # footprints that reach it span 4.7 cm to 23.5 cm.
    test "names the objects the patch sees least of" do
      report =
        Corpus.report([
          row("kinder_guard_dog", {0.047, 0.048, 0.10}),
          row("dog_free_fire", {0.029, 0.094, 0.091}),
          row("dogs_head", {0.044, 0.072, 0.097}),
          row("puppy", {0.065, 0.113, 0.10}),
          row("milka", {0.235, 0.175, 0.092})
        ])

      refute Corpus.comparable?(report)
      assert report.outliers == ["milka"]
      # milka's 23.5 cm against the median footprint of 9.4 cm.
      assert report.spread |> Float.round(1) == 2.5
      assert report.median |> Float.round(3) == 0.094
      assert elem(report.widest, 0) == "milka"
      assert elem(report.narrowest, 0) == "kinder_guard_dog"
    end

    # An object the patch sees *better* than the rest is the same defect the
    # other way round: the memory it builds is denser than every other graph's.
    test "an object far smaller than the median is not comparable either" do
      report =
        Corpus.report([
          row("mug", {0.06, 0.06, 0.10}),
          row("mug2", {0.06, 0.06, 0.10}),
          row("crumb", {0.02, 0.02, 0.10})
        ])

      refute Corpus.comparable?(report)
    end
  end

  test "the footprint is the larger horizontal extent, never the height" do
    assert Corpus.footprints([row("dog", {0.03, 0.09, 0.20})]) == %{"dog" => 0.09}
  end
end
