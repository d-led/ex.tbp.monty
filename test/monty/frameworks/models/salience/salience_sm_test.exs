defmodule Monty.Frameworks.Models.Salience.SensorModule.SalienceSMTest do
  @moduledoc """
  A view finder that says where to look, and nothing else.

  Its output is goals, so these tests are about the three judgements that make
  them: which pixels are on the object, how strongly the sensor's recent visits
  argue against each, and what a goal's confidence ends up meaning. A view whose
  pixels are numbered by their position makes all three readable — the salience
  of a uniform strategy is the same everywhere, and what survives is exactly the
  inhibition and the dither.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.{AttentionRegion, Goal}
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.Salience.ReturnInhibitor
  alias Monty.Frameworks.Models.Salience.SensorModule.SalienceSM
  alias Monty.Frameworks.Models.Salience.Telemetry.DetailedSalienceSMTelemetry
  alias Monty.Geometry.Rotation

  # Three by three, all on the object, one metre away, at x = pixel index.
  defp observation(semantic_ids \\ List.duplicate(1.0, 9)) do
    points =
      for {semantic_id, index} <- Enum.with_index(semantic_ids) do
        [index * 0.01, 0.0, -1.0, semantic_id]
      end

    %{
      "rgba" => List.duplicate(List.duplicate([0.5, 0.5, 0.5, 1.0], 3), 3),
      "depth" => List.duplicate(List.duplicate(1.0, 3), 3),
      "semantic_3d" => points
    }
  end

  defp ctx(seed \\ 0), do: Context.new(seed)

  # A module told where its sensor is, which is what a run does on every step.
  defp sensor(options \\ []) do
    agent = %AgentState{
      position: [0.0, 0.0, 0.0],
      rotation: Rotation.identity(),
      sensors: %{
        "view_finder" => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
      }
    }

    SalienceSM.update_state(agent, SalienceSM.new("view_finder", options))
  end

  defp agent do
    %AgentState{
      position: [0.0, 0.0, 0.0],
      rotation: Rotation.identity(),
      sensors: %{
        "view_finder" => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
      }
    }
  end

  # A sixteen by sixteen view with a bright blob and a near step in the depth:
  # structure at two sizes, which is what an attention model has something to
  # say about.
  defp view_with_a_blob do
    points =
      for row <- 0..15, column <- 0..15 do
        [column * 0.01, row * 0.01, -1.0, 1.0]
      end

    %{
      "rgba" =>
        for row <- 0..15 do
          for column <- 0..15 do
            if row in 4..7 and column in 4..7,
              do: [230.0, 230.0, 230.0, 255.0],
              else: [60.0, 60.0, 60.0, 255.0]
          end
        end,
      "depth" =>
        for row <- 0..15 do
          for column <- 0..15 do
            if row in 6..9 and column in 6..9, do: 0.5, else: 2.0
          end
        end,
      "semantic_3d" => points
    }
  end

  describe "a view of an object" do
    test "proposes one goal per pixel on it, and none from off it" do
      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor())

      {goals, _sensor} = SalienceSM.propose_goals(sensor)
      assert length(goals) == 9
      assert Enum.all?(goals, &match?(%Goal{}, &1))
    end

    test "proposes nothing for a view that is all background" do
      {nil, sensor} = SalienceSM.step(observation(List.duplicate(0.0, 9)), false, ctx(), sensor())

      assert {[], _sensor} = SalienceSM.propose_goals(sensor)
    end

    test "gives every goal a confidence a motor system can weigh" do
      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor())

      {goals, _sensor} = SalienceSM.propose_goals(sensor)
      assert Enum.all?(goals, &(&1.confidence >= 0.0 and &1.confidence <= 1.0))

      # A goal is for the motor system, not for a learning module: the sensor
      # says where to look, not what is there.
      assert Enum.all?(goals, &(&1.pass_message == false))
      assert Enum.all?(goals, &(&1.process_features_in_lm == false))
    end

    test "keeps the ordering of the view: the first goal is the first pixel" do
      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor())

      {[first | _rest], _sensor} = SalienceSM.propose_goals(sensor)
      assert first.location == [0.0, 0.0, -1.0]
    end
  end

  describe "the same view again" do
    test "is proposed with the place already looked at suppressed" do
      # The first step records where the middle of the view was; the second sees
      # that visit weighing against the pixels nearest to it, so the goal at the
      # centre is not the most confident one any more.
      {nil, after_first} = SalienceSM.step(observation(), false, ctx(), sensor())
      {_nil, sensor} = SalienceSM.step(observation(), false, ctx(), after_first)

      {goals, _sensor} = SalienceSM.propose_goals(sensor)
      confidences = Enum.map(goals, & &1.confidence)

      refute Enum.max(confidences) == Enum.at(confidences, 4)
    end
  end

  describe "a motor-only step" do
    test "proposes nothing and leaves what it proposed in place" do
      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor())
      {goals, _module_that_proposed} = SalienceSM.propose_goals(sensor)

      {nil, after_motor} = SalienceSM.step(observation(), true, ctx(), sensor)

      assert {^goals, _sensor} = SalienceSM.propose_goals(after_motor)
    end
  end

  describe "a view with no segmentation strategy" do
    test "proposes no region, which is a module that only proposes goals" do
      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor())

      assert {region, _sensor} = SalienceSM.propose_region(sensor)
      assert region == AttentionRegion.empty()
    end
  end

  describe "a view with a segmentation strategy" do
    defmodule SegmentsTheMiddleColumn do
      @moduledoc false
      # A stand-in for SLIC: says the middle column of the view is one segment.
      # What it is here to specify is the *intersection* — a region is the
      # segmented pixels that are also on the object.
      @behaviour Monty.Frameworks.Models.Salience.Segmentation.Strategy.SegmentationStrategy

      defstruct []

      def new, do: %__MODULE__{}

      @impl true
      def call(%__MODULE__{}, _ctx, rgb) do
        {Enum.map(rgb, fn row -> Enum.map(row, fn _pixel -> 0 end) end) |> then(&put_middle/1),
         %__MODULE__{}}
      end

      defp put_middle(rows) do
        Enum.map(rows, fn [_left, _middle, _right] = row -> List.replace_at(row, 1, 1) end)
      end
    end

    test "proposes the region under fixation, and only the pixels on the object" do
      # The middle pixel is background: the segmented column is three pixels,
      # but only the two of them that are on the object belong to the region.
      off_centre = observation([1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 1.0, 1.0, 1.0])

      sensor =
        sensor(segmentation_strategy: {SegmentsTheMiddleColumn, SegmentsTheMiddleColumn.new()})

      {nil, sensor} = SalienceSM.step(off_centre, false, ctx(), sensor)

      {region, _sensor} = SalienceSM.propose_region(sensor)

      # Column 1 of each row: x is 1, 4 and 7 hundredths of a metre.
      assert region.locations == [[0.01, 0.0, -1.0], [0.07, 0.0, -1.0]]

      assert region.weights == [
               Monty.Cmp.AttentionRegion.max_weight(),
               Monty.Cmp.AttentionRegion.max_weight()
             ]
    end
  end

  describe "telemetry" do
    test "is recorded when the config asks for it" do
      sensor =
        sensor(telemetry: {DetailedSalienceSMTelemetry, DetailedSalienceSMTelemetry.new()})

      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor)

      state = SalienceSM.state_dict(sensor)
      assert [%{"semantic_3d" => _points}] = state.raw_observations
      assert [salience_map] = state.salience_maps
      assert length(List.flatten(salience_map)) == 9
      assert [goals] = state.goals
      assert length(goals) == 9
    end

    test "keeps nothing when the config does not, but still answers every key" do
      {nil, sensor} = SalienceSM.step(observation(), false, ctx(), sensor())

      assert %{
               raw_observations: [],
               sm_properties: [],
               salience_maps: [],
               segmentation_maps: [],
               goals: [],
               attention_regions: []
             } = SalienceSM.state_dict(sensor)
    end
  end

  describe "the module a config describes" do
    test "is built from the entry Monty's surf configurations write" do
      # `camera_dist_delta_salience.yaml`'s `sensor_module_1`: an id and nothing
      # else, which means every strategy is Monty's default.
      assert {:ok, sensor} =
               SalienceSM.from_config(%{
                 "_target_" => "tbp.monty.frameworks.models.salience.sensor_module.SalienceSM",
                 "sensor_module_id" => "view_finder"
               })

      assert sensor.sensor_module_id == "view_finder"

      assert {Monty.Frameworks.Models.Salience.Strategies.Uniform, _strategy} =
               sensor.salience_strategy

      assert {ReturnInhibitor, _inhibitor} = sensor.return_inhibitor
      assert sensor.segmentation_strategy == nil
    end

    test "declines a sensor another class owns" do
      assert {:error, {:unsupported_sensor_module, _target}} =
               SalienceSM.from_config(%{
                 "_target_" => "tbp.monty.frameworks.models.sensor_modules.CameraSM",
                 "sensor_module_id" => "patch"
               })
    end

    test "declines a strategy this port has not written" do
      # A bare `Vocus2` is not something an experiment writes — the class takes
      # three built channel processors — so a config that names it is refused
      # rather than given a uniform view in its place.
      assert {:error, {:unsupported_layer, "salience_strategy", target}} =
               SalienceSM.from_config(%{
                 "_target_" => "tbp.monty.frameworks.models.salience.sensor_module.SalienceSM",
                 "sensor_module_id" => "view_finder",
                 "salience_strategy" => %{
                   "_target_" => "tbp.monty.frameworks.models.salience.strategies.vocus2.Vocus2"
                 }
               })

      assert target =~ "Vocus2"
    end
  end

  describe "a configuration that names VOCUS2" do
    # The real thing, composed from Monty's own experiment rather than written
    # out here: if the YAML's shape changes, this fails.
    setup do
      {:ok, view_finder: vocus2_view_finder()}
    end

    test "builds the strategy the experiment asks for", %{view_finder: view_finder} do
      assert {:ok, sensor} = SalienceSM.from_config(view_finder)

      assert {Monty.Frameworks.Models.Salience.Strategies.Vocus2, strategy} =
               sensor.salience_strategy

      # `camera_dist_vocus2.yaml`'s numbers, and the channel it turns off.
      assert strategy.color.center_sigma == 1.0
      assert strategy.color.surround_sigma == 6.5
      assert strategy.color.n_scales == 2
      assert strategy.color.max_octaves == 5
      assert strategy.depth != nil
      assert strategy.orientation == nil
    end

    test "proposes goals from the salience it computes", %{view_finder: view_finder} do
      {:ok, sensor} = SalienceSM.from_config(view_finder)
      sensor = SalienceSM.update_state(agent(), sensor)

      {nil, sensor} = SalienceSM.step(view_with_a_blob(), false, ctx(), sensor)

      {goals, _sensor} = SalienceSM.propose_goals(sensor)

      # One goal per pixel on the object, and an empty region: `camera_dist_vocus2`
      # names no segmentation strategy, so the sensor says where to look and not
      # how much of the surface to attend to.
      assert length(goals) == 16 * 16
      assert Enum.all?(goals, &match?(%Goal{}, &1))
      assert sensor.region == AttentionRegion.empty()
    end
  end

  # Monty's `supervised_pre_training_10distinctobj_vocus2` view finder, composed
  # from the YAML rather than transcribed.
  defp vocus2_view_finder do
    {:ok, tree} = Monty.Config.Composer.compose("supervised_pre_training_10distinctobj_vocus2")

    get_in(tree, ["experiment", "config", "monty_config", "sensor_modules", "sensor_module_1"])
  end
end
