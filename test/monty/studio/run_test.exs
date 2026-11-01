defmodule Monty.Studio.RunTest do
  @moduledoc """
  An episode is stepped in a mode, and the model is told which one.

  Every episode of a run is a fresh model, so the mode is not left over from an
  epoch: it arrives with the run. Monty tells its model once per epoch
  (`MontyExperiment.evaluate/1` → `set_experiment_mode/1`) and `pre_episode`
  resets it; this port starts a model per episode and must therefore say it every
  time.

  Nothing else does. A model that was told nothing steps with
  `experiment_mode: nil`, whose ending rule has no branch: an evaluation that
  recognises its object neither stops nor switches to exploring, so the episode
  runs until the page's step budget cuts it off and the run concludes nothing.
  That is exactly what every run of this port did before this test existed.
  """

  use ExUnit.Case, async: false

  alias Monty.Runtime.Model
  alias Monty.Studio.Run

  @experiment "base_10simobj_surf_agent"

  defp start(options) do
    {:ok, opened} = Monty.Studio.open(@experiment)
    {:ok, run} = Run.start(opened.setup, Keyword.put(options, :steps, 4))

    on_exit(fn -> Run.stop(run) end)
    run
  end

  test "an evaluation tells the model it is evaluating" do
    run = start([])

    assert Model.state(run.model_id).experiment_mode == :eval
  end

  test "a training episode tells the model it is training" do
    run = start(mode: :train)

    assert Model.state(run.model_id).experiment_mode == :train
    # The policy measures its limits in matching steps of *this* mode, so the
    # counter is the mode's too.
    assert run.counter.mode == :train
  end
end
