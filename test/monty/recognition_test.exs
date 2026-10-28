defmodule Monty.RecognitionTest do
  @moduledoc """
  The loop every Monty experiment runs, end to end.

  A sensor walks a surface, an evidence learning module builds a graph of what it
  saw, and on a later pass over a surface the module narrows its memory down to
  one object and one pose. Everything here is the real pipeline —
  `Monty.Runtime.Step` stepping the modules, `Monty.Runtime.Episode` walking the
  episodes, `EvidenceGraphLM` accumulating evidence — except the world, which is
  the simulator the runtime is developed against.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
  alias Monty.Simulators.Synthetic.{Environment, Motor, SensorModule}

  @agent "agent_id_0"
  @channel "patch"

  # The pose the synthetic sensor reports, as a graph stores it.
  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  # A surface the synthetic sensor can walk: values rising along x, at the
  # height the sensor looks from.
  defp object(id, offset) do
    positions = for step <- 0..11, do: step * 0.01

    features = %{
      "value" => Enum.map(positions, &[&1 + offset]),
      "pose_vectors" => List.duplicate(@pose, length(positions)),
      "pose_fully_defined" => List.duplicate([1.0], length(positions))
    }

    model =
      GraphObjectModel.new(id)
      |> GraphObjectModel.build_model(
        Enum.map(positions, &[&1, 0.0, 0.1]),
        features,
        nil,
        nil
      )

    {%{@channel => model}, id}
  end

  defp memory(objects) do
    Enum.reduce(objects, GraphMemory.new(), fn {model, id}, memory ->
      GraphMemory.add_graph_to_memory(memory, model, id)
    end)
  end

  defp start_model(memory) do
    model_id = "recognition-#{System.unique_integer([:positive])}"

    {:ok, lm} =
      EvidenceGraphLM.new(memory,
        max_match_distance: 0.05,
        tolerances: %{@channel => %{"value" => 0.05}},
        feature_weights: %{@channel => %{"value" => 1.0}},
        # Two surviving alternatives and the pose is accepted: the surfaces here
        # are featureless plates, so their mirror images never disagree.
        required_symmetry_evidence: 2,
        learning_module_id: "LM_0"
      )

    spec = %{
      model_id: model_id,
      sensor_modules: [
        %{
          id: @channel,
          agent_id: @agent,
          module: SensorModule,
          state: SensorModule.new(@channel)
        }
      ],
      learning_modules: [%{id: :lm_0, module: EvidenceGraphLM, state: lm}],
      sm_to_lm: %{lm_0: [@channel]},
      motor: {Motor, Motor.new()},
      num_exploratory_steps: 12
    }

    start_supervised!(Supervisor.child_spec({Model, spec}, id: model_id))
    model_id
  end

  # The sensor walking along a surface, one centimetre per step, starting again
  # at the beginning whenever the episode is rewound.
  defp walk do
    {:ok, position} = Agent.start_link(fn -> 0 end)

    environment = fn _actions ->
      step = Agent.get_and_update(position, fn step -> {step, step + 1} end)
      Environment.observations(step, [@channel])
    end

    rewind = fn -> Agent.update(position, fn _step -> 0 end) end

    {environment, rewind}
  end

  defp learning_module(model_id) do
    LearningModuleServer.state(Registry.via({:learning_module, model_id, :lm_0}))
  end

  defp remembered_objects(model_id) do
    model_id |> learning_module() |> Map.fetch!(:graph_memory) |> GraphMemory.get_memory_ids()
  end

  describe "learning an object" do
    test "the first pass stores what the sensor walked over" do
      model_id = start_model(GraphMemory.new())
      {environment, _rewind} = walk()

      result = Episode.run(model_id, environment, mode: :train, max_steps: 30)

      # Nothing was in memory, so the only conclusion available is that this is
      # a new object — which is what a training episode stores.
      assert result.terminal_states == %{lm_0: :no_match}
      assert learning_module(model_id).detected_object == "new_object0"
      assert remembered_objects(model_id) == ["new_object0"]
    end

    test "the next pass recognises what the first one stored" do
      model_id = start_model(GraphMemory.new())
      {environment, rewind} = walk()

      Episode.run(model_id, environment, mode: :train, max_steps: 30)
      rewind.()

      recognised = Episode.run(model_id, environment, mode: :eval, max_steps: 30)

      assert recognised.terminal_states == %{lm_0: :match}
      assert learning_module(model_id).detected_object == "new_object0"

      # Where along the walk it settled depends on how many steps the evidence
      # needed; that it settled on the surface, facing the way it was seen, does
      # not.
      assert [x, 0.0, 0.1, rx, ry, rz, 1] = learning_module(model_id).detected_pose
      assert x >= 0.0 and x <= 0.12
      assert Enum.all?([rx, ry, rz], &(&1 == 0.0))
    end
  end

  describe "telling objects apart" do
    setup do
      objects = [object("near", 0.0), object("far", 1.0)]
      %{model_id: start_model(memory(objects))}
    end

    test "picks the object whose surface the sensor is on", %{model_id: model_id} do
      {environment, rewind} = walk()

      result = Episode.run(model_id, environment, mode: :eval, max_steps: 30)
      assert result.terminal_states == %{lm_0: :match}
      assert learning_module(model_id).detected_object == "near"

      rewind.()
      {further, _rewind} = walk()

      shifted = fn actions ->
        {observations, proprioceptive_state} = further.(actions)
        seen = get_in(observations, [@agent, @channel])

        shifted =
          put_in(observations, [@agent, @channel], %{seen | "value" => seen["value"] + 1.0})

        {shifted, proprioceptive_state}
      end

      result = Episode.run(model_id, shifted, mode: :eval, max_steps: 30)
      assert result.terminal_states == %{lm_0: :match}
      assert learning_module(model_id).detected_object == "far"
    end
  end
end
