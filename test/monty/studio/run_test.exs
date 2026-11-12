defmodule Monty.Studio.RunTest do
  @moduledoc """
  An episode is stepped in a mode, and the model is told which one.

  An episode arrives with its mode rather than inheriting it: Monty tells its
  model once per epoch (`MontyExperiment.evaluate/1` → `set_experiment_mode/1`),
  and this port says it on every episode start, because a model can be reused
  across episodes of a phase and a phase is not a module's business.

  Nothing else does. A model that was told nothing steps with
  `experiment_mode: nil`, whose ending rule has no branch: an evaluation that
  recognises its object neither stops nor switches to exploring, so the episode
  runs until the page's step budget cuts it off and the run concludes nothing.
  That is exactly what every run of this port did before this test existed.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
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

  describe "a model that outlives an episode" do
    test "is reset for the next one rather than built again" do
      # `Monty.Runtime.Episode.run/3` is a model given an id and reset per episode,
      # and a run is that loop with an experiment around it. Building one per
      # episode paid for the memory's graphs every time — 895 ms of a 1.7 s
      # episode on the ten-object config — so a model started under an id this run
      # already has is the same process, cleared and stepped again.
      {:ok, opened} = Monty.Studio.open(@experiment)
      {:ok, first} = Run.start(opened.setup, steps: 4, episode: 1, model_id: "studio-hold-test")
      assert [{pid, _}] = registered(Model.via("studio-hold-test"))

      {:ok, second} = Run.start(opened.setup, steps: 4, episode: 2, model_id: "studio-hold-test")

      on_exit(fn ->
        Run.stop_world(first)
        Run.stop_world(second)
        Run.stop_model(second)
      end)

      assert [{^pid, _}] = registered(Model.via("studio-hold-test"))
      assert second.model_id == first.model_id
    end
  end

  # The model a `:via` name resolves to, which is how "the model is the same
  # process" is asked.
  defp registered({:via, Registry, {registry, key}}), do: Registry.lookup(registry, key)

  describe "the memory an episode is given" do
    # A phase is many episodes and one memory. Monty keeps one model between them
    # — a training episode writes into its memory and the next episode matches
    # against what it wrote — while this port starts a model per episode. The
    # memory has to be handed on, or a training phase would learn and forget in
    # the same breath; that hand-off is the whole of what training needs beyond
    # an evaluation phase.
    defp open do
      {:ok, opened} = Monty.Studio.open(@experiment)
      opened.setup
    end

    defp episode(setup, options) do
      {:ok, run} = Run.start(setup, [steps: 60] ++ options)
      :ok = Run.set_ground_truth(run)
      on_exit(fn -> Run.stop(run) end)

      run
    end

    defp stepped(run), do: step_until_over(run, 60)

    defp step_until_over(run, 0), do: run

    defp step_until_over(run, left) do
      {:ok, _info, _observations, run} = Run.step(run)

      if Run.finished?(run), do: run, else: step_until_over(run, left - 1)
    end

    defp remembered(run) do
      run |> Run.memories() |> Map.fetch!(only_module(run.setup)) |> GraphMemory.get_memory_ids()
    end

    # A config names its modules (`learning_module_0` here, `:lm_0` elsewhere), so
    # the memory is keyed by whatever the setup says.
    defp only_module(setup), do: setup.learning_modules |> hd() |> Map.fetch!(:id)

    defp empty_memory(setup), do: %{only_module(setup) => GraphMemory.new()}

    test "a training episode writes what it saw" do
      setup = open()
      run = setup |> episode(mode: :train, memory: empty_memory(setup)) |> stepped()
      assert remembered(run) == []

      :ok = Run.update_ltm(run)

      # Nothing to match against, so what it walked is a new object — Monty's
      # `"new_object<n>"`, which is the whole of unsupervised learning.
      assert remembered(run) == ["new_object0"]
    end

    test "an evaluation episode writes nothing" do
      setup = open()
      run = setup |> episode(mode: :eval, memory: empty_memory(setup)) |> stepped()

      :ok = Run.update_ltm(run)

      assert remembered(run) == []
    end

    test "the next episode starts from what the last one wrote" do
      setup = open()
      trained = setup |> episode(mode: :train, memory: empty_memory(setup)) |> stepped()
      :ok = Run.update_ltm(trained)

      next = episode(setup, mode: :eval, memory: Run.memories(trained))

      # Nothing has stepped yet, so this is the memory the run was started with.
      assert remembered(next) == ["new_object0"]
    end
  end
end
