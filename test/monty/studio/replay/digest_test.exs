defmodule Monty.Studio.Replay.DigestTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Replay.Digest
  alias Monty.Studio.RunHistory.Run

  # A run as the record keeps it: one log entry and one moment per step.
  defp run(steps) do
    %Run{timeline: Enum.map(steps, &moment/1), log: Enum.map(steps, &entry/1)}
  end

  defp moment(step) do
    %{
      "step" => step,
      "sensors" => %{"patch" => %{"location" => [step * 0.01, 0.0, 0.1]}}
    }
  end

  defp entry(step, evidence \\ nil) do
    %{
      "step" => step,
      "episode" => 0,
      "percepts" => ["patch"],
      "votes" => %{"used" => 1},
      "duration_us" => 100 + step
    }
    |> believing(evidence)
  end

  defp believing(entry, nil), do: entry

  defp believing(entry, evidence),
    do: Map.put(entry, "beliefs", %{"learning_module_0" => %{"graphs" => graphs(evidence)}})

  defp graphs(evidence) when is_number(evidence),
    do: %{"mug" => %{"max_evidence" => evidence}}

  defp graphs(by_object), do: Map.new(by_object, fn {o, e} -> {o, %{"max_evidence" => e}} end)

  describe "a digest of the steps that arrived" do
    test "answers what one pass over the whole run answers" do
      whole = run(0..40) |> Digest.from()

      entries = Enum.map(0..40, &{&1, entry(&1)})
      moments = Enum.map(0..40, &{&1, moment(&1)})

      in_two_halves =
        Digest.new()
        |> Digest.append(Enum.take(entries, 20), Enum.take(moments, 20))
        |> Digest.append(Enum.drop(entries, 20), Enum.drop(moments, 20))

      assert Digest.count(in_two_halves) == 41
      assert Digest.count(whole) == 41
      assert Digest.series(in_two_halves) == Digest.series(whole)
      assert Digest.objects(in_two_halves) == Digest.objects(whole)
      assert Digest.modules(in_two_halves) == Digest.modules(whole)
      assert Digest.best(in_two_halves) == Digest.best(whole)
    end

    test "counts a step once, however often it is handed one" do
      digest =
        Digest.new()
        |> Digest.append([{0, entry(0, 5.0)}, {0, entry(0, 5.0)}], [])
        |> Digest.append([{0, entry(0, 5.0)}], [])

      assert Digest.count(digest) == 1

      assert [%{points: [_one_point]}] =
               Digest.objects(digest) |> Enum.filter(&(&1.id == "object:mug"))
    end
  end

  describe "the points a line keeps" do
    test "are one a step for a run short enough to keep them" do
      digest = run(0..9) |> Digest.from()
      evidence = Digest.series_of(digest, "duration_us")

      assert evidence.points |> Enum.map(& &1.step) == Enum.to_list(0..9)
    end

    test "are bounded for a long run, and still span it" do
      digest = run(0..19_999) |> Digest.from()

      for series <- Digest.series(digest) do
        steps = series.points |> Enum.map(& &1.step)

        assert length(steps) < 2_000, "#{series.id} kept #{length(steps)} points"
        assert hd(steps) == 0
        assert List.last(steps) == 19_999
        assert steps == Enum.sort(steps)
      end
    end

    test "keep a run's highest point even where the run is thinned" do
      # A peak in the middle of twenty thousand steps is the thing a chart of the
      # run exists to show: grouping steps may drop the steps around it, never it.
      log =
        for step <- 0..19_999 do
          entry(step, if(step == 11_111, do: 99.0, else: rem(step, 7) * 1.0))
        end

      digest = Digest.from(%Run{log: log, timeline: []})

      assert Digest.series_of(digest, "evidence").points |> Enum.map(& &1.value) |> Enum.max() ==
               99.0

      assert Digest.best(digest) == %{object: "mug", value: 99.0}
    end
  end
end
