defmodule Monty.Frameworks.Models.Salience.SalienceParityTest do
  @moduledoc """
  The port answers what Monty answers.

  `scripts/record_monty_salience.py` ran Monty's own salience classes over a few
  inputs and wrote down what they answered; this replays them. The unit tests
  pin each rule on its own — half-lives, cutoff, expiry, the middle pixel — while
  these pin whole answers, where several rules meet at once.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.OnObjectObservation
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.{DecayField, DecayKernelFactory}

  @fixtures Path.expand("../../../../fixtures", __DIR__)

  describe "inhibition of return" do
    setup do
      %{"trajectories" => trajectories} =
        @fixtures |> Path.join("monty_salience_inhibitor.json") |> File.read!() |> Jason.decode!()

      {:ok, trajectories: trajectories}
    end

    test "every recorded trajectory is answered weight for weight", %{trajectories: trajectories} do
      for %{"kernel" => kernel, "queries" => queries, "steps" => steps} <- trajectories do
        inhibitor =
          ReturnInhibitor.new(decay_field: DecayField.new(kernel_factory: factory(kernel)))

        assert_answers(inhibitor, queries, steps)
      end
    end

    defp assert_answers(inhibitor, queries, [
           %{"visited_location" => visit, "weights" => expected} | rest
         ]) do
      {weights, inhibitor} = ReturnInhibitor.call(inhibitor, visit, queries)

      expected
      |> Enum.zip(weights)
      |> Enum.each(fn {monty, port} -> assert_in_delta port, monty, 1.0e-9 end)

      assert_answers(inhibitor, queries, rest)
    end

    defp assert_answers(_inhibitor, _queries, []), do: :ok

    defp factory(%{
           "tau_t" => tau_t,
           "tau_s" => tau_s,
           "spatial_cutoff" => cutoff,
           "w_t_min" => w_t_min
         }) do
      DecayKernelFactory.new(tau_t: tau_t, tau_s: tau_s, spatial_cutoff: cutoff, w_t_min: w_t_min)
    end
  end

  describe "a view as grids" do
    setup do
      %{"views" => views} =
        @fixtures
        |> Path.join("monty_on_object_observation.json")
        |> File.read!()
        |> Jason.decode!()

      {:ok, views: views}
    end

    test "every recorded view is reshaped the way Monty reshapes it", %{views: views} do
      for %{"row_column_shape" => [rows, columns], "expected" => expected} = view <- views do
        observation =
          Map.merge(view, %{
            "rgba" => List.duplicate(List.duplicate([1.0, 1.0, 1.0, 1.0], columns), rows),
            "depth" => List.duplicate(List.duplicate(1.0, columns), rows)
          })

        matched = OnObjectObservation.from(observation, view["salience_map"])

        assert matched.centre_location == expected["center_location"]
        assert matched.on_object_map == expected["on_object_map"]
        assert matched.location_map == expected["location_map"]
        assert matched.locations == expected["locations"]
        assert matched.salience == expected["salience"]
      end
    end
  end
end
