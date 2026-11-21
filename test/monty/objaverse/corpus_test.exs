defmodule ExTbpMonty.Objaverse.CorpusTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Objaverse.Corpus

  # The import's own row, cut down to what the comparability rule reads: the
  # surface area a memory's node count follows, and the extents a policy walks.
  defp row(id, area, {x, y, z}), do: %{id: id, area: area, size: {x, y, z}}

  describe "a corpus the patch can treat alike" do
    test "objects of one area are comparable" do
      report =
        Corpus.report([
          row("plate", 0.020, {0.06, 0.05, 0.10}),
          row("mug", 0.019, {0.05, 0.06, 0.10})
        ])

      assert Corpus.comparable?(report)
      assert report.outliers == []
      # The median of an even count is the mean of the middle two: 0.0195 m², so
      # the larger object is 1.03 times it.
      assert report.spread |> Float.round(2) == 1.03
    end

    # Shapes differ; that is not the question. Two objects with the same surface
    # fill a patch's cells at the same rate whatever their proportions.
    test "different shapes of one area are comparable" do
      report =
        Corpus.report([
          row("tall", 0.02, {0.06, 0.06, 0.12}),
          row("long", 0.02, {0.20, 0.05, 0.04})
        ])

      assert Corpus.comparable?(report)
    end

    test "one object is comparable with itself" do
      assert Corpus.comparable?(Corpus.report([row("only", 0.06, {0.23, 0.17, 0.09})]))
    end
  end

  describe "a corpus that is not" do
    # Measured on the dogs before the import normalised area: one height for the
    # five, and the surface that reaches it spans 0.013 m² to 0.059 m².
    test "names the objects the patch fills fastest" do
      report =
        Corpus.report([
          row("kinder_guard_dog", 0.0133, {0.05, 0.051, 0.10}),
          row("dog_free_fire", 0.0140, {0.032, 0.095, 0.091}),
          row("dogs_head", 0.0146, {0.049, 0.074, 0.097}),
          row("puppy", 0.0208, {0.067, 0.117, 0.10}),
          row("milka", 0.0586, {0.241, 0.183, 0.10})
        ])

      refute Corpus.comparable?(report)
      assert report.outliers == ["milka"]
      assert report.spread |> Float.round(1) == 4.0
      assert report.median |> Float.round(4) == 0.0146
      assert elem(report.widest, 0) == "milka"
      assert elem(report.narrowest, 0) == "kinder_guard_dog"
    end

    # An object far smaller than the median is the same defect the other way
    # round: its graph fills slower than every other object's.
    test "an object far smaller than the median is not comparable either" do
      report =
        Corpus.report([
          row("mug", 0.020, {0.06, 0.06, 0.10}),
          row("mug2", 0.020, {0.06, 0.06, 0.10}),
          row("crumb", 0.004, {0.02, 0.02, 0.10})
        ])

      refute Corpus.comparable?(report)
    end
  end

  test "the footprint is the larger horizontal extent, never the height" do
    assert Corpus.footprints([row("dog", 0.02, {0.03, 0.09, 0.20})]) == %{"dog" => 0.09}
  end

  test "a row without an area counts as nothing rather than crashing the report" do
    assert Corpus.areas([%{id: "old", size: {0.05, 0.05, 0.1}}]) == %{"old" => 0.0}
  end
end
