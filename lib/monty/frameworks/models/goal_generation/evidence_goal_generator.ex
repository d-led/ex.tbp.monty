defmodule Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator do
  @moduledoc """
  Look where the candidates disagree most, then look again.

  Mirrors `tbp/monty/frameworks/models/goal_generation.py::EvidenceGoalGenerator`,
  the goal-state generator that turns "I cannot tell these objects apart" into
  one concrete place to look. It compares the graph of the most likely object
  with the graph of the second most likely one, and asks for the point on the
  first that is farthest from anything on the second: a mug's handle, when the
  alternatives are handleless cups.

  Monty subclasses `GraphGoalGenerator`; Elixir has no inheritance, so this
  holds one instead and delegates the parts Monty does not override — the parent
  module, the goal itself, and the crude "did the sensory input change" test for
  whether the last goal was reached. What the subclass does override is all
  here: when to look somewhere new, where, and the goal that points there.

  ## The schedule

  A hypothesis jump is a gamble: move to where the two candidates disagree, and
  the observation there should favour one of them. Gambling every step makes the
  agent walk back and forth over the object and learn nothing, so
  `check_conditions_for_hypothesis_test/2` spends most steps matching and jumps
  when the odds are good:

    * never, until `min_post_goal_success_steps` steps have passed since the
      last goal — Monty's default is `:infinity`, so only an experiment that
      asks for it jumps at all;
    * when one object is left but several poses, to separate the poses;
    * when one object is clearly ahead but not certain, on half the occasions;
    * when the top two objects change, or the most likely pose does;
    * otherwise, every `wait_factor * elapsed_steps_factor` steps, with
      `wait_factor` doubling after each jump so a test that taught nothing is
      not repeated on a schedule that keeps spending.

  ## A quirk kept on purpose

  Monty writes both the top-two check and the pose check as `np.all(...)`, so
  they fire only when *every* compared value differs: both object ids must
  change, and all three Euler angles must change. That is stricter than the
  comment above it ("a change or shuffle in top-two MLH IDs") describes, and it
  is reproduced rather than corrected, because correcting it would change when
  the agent moves and make our numbers incomparable with Monty's.
  """

  @behaviour Monty.Frameworks.Models.AbstractMontyClasses.GoalGenerator

  require Logger

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GoalGeneration.GraphGoalGenerator
  alias Monty.Frameworks.Utils.{CommunicationUtils, SpatialArithmetics}
  alias Monty.Geometry.{GazeDirection, Rotation}

  # Monty's constructor defaults.
  @default_elapsed_steps_factor 10
  @default_x_percent_scale_factor 0.75
  @default_desired_object_distance 0.03
  @default_wait_growth_multiplier 2

  # How far past the surface a gaze goal is placed, as a multiple of the desired
  # object distance: far enough that reaching it is easy, near enough that the
  # sensor sees the target.
  @stand_off_multiple 1.5

  # The coin flipped when the most likely object is ahead but not certain.
  @pose_focus_probability 0.5

  defstruct base: nil,
            focus_on_pose: false,
            wait_factor: 1,
            prev_top_mlhs: nil,
            elapsed_steps_factor: @default_elapsed_steps_factor,
            min_post_goal_success_steps: :infinity,
            x_percent_scale_factor: @default_x_percent_scale_factor,
            desired_object_distance: @default_desired_object_distance,
            wait_growth_multiplier: @default_wait_growth_multiplier

  @typedoc """
  The most likely hypothesis of an object, or of everything: what
  `EvidenceGraphLM.get_mlh_for_object/2` answers.
  """
  @type mlh :: EvidenceGraphLM.mlh()

  @typedoc """
  Where to look: which hypothesis would be tested, and the point on its graph.

  `target_surface_normal` is the learned normal of that node, in the object's
  own frame — the direction a sensor has to face to observe it.
  """
  @type target_info :: %{
          hypothesis_to_test: mlh(),
          target_loc: [float()],
          target_surface_normal: [float()]
        }

  @type t :: %__MODULE__{
          base: GraphGoalGenerator.t(),
          focus_on_pose: boolean(),
          wait_factor: pos_integer(),
          prev_top_mlhs: [mlh()] | nil,
          elapsed_steps_factor: pos_integer(),
          min_post_goal_success_steps: non_neg_integer() | :infinity,
          x_percent_scale_factor: number(),
          desired_object_distance: number(),
          wait_growth_multiplier: number()
        }

  @doc """
  A generator that has not looked anywhere yet.

  Options are `:parent_lm` (the learning module to read), `:goal_tolerances` and
  `:parent_output` (handed to the base generator), and Monty's five schedule
  parameters: `:elapsed_steps_factor`, `:min_post_goal_success_steps`,
  `:x_percent_scale_factor`, `:desired_object_distance` and
  `:wait_growth_multiplier`.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      base:
        options
        |> GraphGoalGenerator.new()
        |> with_parent_lm(Keyword.get(options, :parent_lm)),
      elapsed_steps_factor:
        Keyword.get(options, :elapsed_steps_factor, @default_elapsed_steps_factor),
      min_post_goal_success_steps: Keyword.get(options, :min_post_goal_success_steps, :infinity),
      x_percent_scale_factor:
        Keyword.get(options, :x_percent_scale_factor, @default_x_percent_scale_factor),
      desired_object_distance:
        Keyword.get(options, :desired_object_distance, @default_desired_object_distance),
      wait_growth_multiplier:
        Keyword.get(options, :wait_growth_multiplier, @default_wait_growth_multiplier)
    }
  end

  defp with_parent_lm(base, nil), do: base

  defp with_parent_lm(base, parent_lm) when is_map(parent_lm),
    do: GraphGoalGenerator.put_parent_lm(base, parent_lm)

  @doc """
  The generator a config entry describes.

  The entry is Monty's `gsg:` under a learning module — `goal_tolerances` by
  feature, then the schedule: how many steps without a goal before one is worth
  trying, the `x` percent scale factor, how close to the object a goal counts as
  reached, and how fast the wait between attempts grows.
  """
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      goal_tolerances: Map.get(config, "goal_tolerances"),
      elapsed_steps_factor:
        Map.get(config, "elapsed_steps_factor", @default_elapsed_steps_factor),
      min_post_goal_success_steps: Map.get(config, "min_post_goal_success_steps", :infinity),
      x_percent_scale_factor:
        Map.get(config, "x_percent_scale_factor", @default_x_percent_scale_factor),
      desired_object_distance:
        Map.get(config, "desired_object_distance", @default_desired_object_distance),
      wait_growth_multiplier:
        Map.get(config, "wait_growth_multiplier", @default_wait_growth_multiplier)
    )
  end

  @doc """
  The learning module this generator reads, or an error when there is none.
  """
  @impl true
  @spec parent_lm(t()) :: struct()
  def parent_lm(%__MODULE__{base: base}), do: GraphGoalGenerator.parent_lm(base)

  @doc """
  Points this generator at its learning module and resets it.

  The schedule is part of the reset: `wait_factor` and `prev_top_mlhs` describe
  what this module has already tried, and another module's tries say nothing
  about this one.
  """
  @impl true
  @spec put_parent_lm(t(), struct()) :: t()
  def put_parent_lm(%__MODULE__{} = generator, parent_lm) do
    base = GraphGoalGenerator.put_parent_lm(generator.base, parent_lm)
    reset(%{generator | base: base})
  end

  @doc """
  The same generator, now reading `parent_lm` as it stands.

  Someone driving this generator step by step has the module's current value
  in hand and the generator has a copy; this swaps the copy without throwing
  away the schedule. See `GraphGoalGenerator.point_at/2`.
  """
  @spec point_at(t(), map()) :: t()
  def point_at(%__MODULE__{} = generator, parent_lm),
    do: %{generator | base: GraphGoalGenerator.point_at(generator.base, parent_lm)}

  @doc "Receives the high-level goal to drive towards; unused, as in Monty."
  @impl true
  @spec set_driving_goal(t(), Goal.t() | nil) :: t()
  def set_driving_goal(%__MODULE__{} = generator, goal),
    do: %{generator | base: GraphGoalGenerator.set_driving_goal(generator.base, goal)}

  @doc "The goal this generator wants others to achieve, or none."
  @impl true
  @spec output_goals(t()) :: [Goal.t()]
  def output_goals(%__MODULE__{base: base}), do: GraphGoalGenerator.output_goals(base)

  @doc """
  Forgets the goal in hand, the schedule, and the log.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = generator) do
    %{
      generator
      | base: GraphGoalGenerator.reset(generator.base),
        focus_on_pose: false,
        wait_factor: 1,
        prev_top_mlhs: nil
    }
  end

  @doc """
  One step: log whether the last goal was reached, then decide what to do.

  Reaching the goal is *not* a reason to want a new one — it means the agent
  arrived, and arriving is where the judging happens — so an achieved goal is
  dropped. A goal that was not achieved is dropped too: hypothesis tests are
  one-off attempts, because an unreachable goal repeated forever is a loop.
  """
  @impl true
  @spec step(t(), Context.t(), [Monty.Cmp.Message.t()]) :: t()
  def step(%__MODULE__{} = generator, ctx, observations) do
    achieved? = GraphGoalGenerator.output_goal_achieved?(generator.base, observations)

    generator =
      %{generator | base: GraphGoalGenerator.log_goal_state(generator.base, achieved?)}

    case need_new_output_goal?(generator, ctx, achieved?) do
      {true, generator} -> generate_goal(generator, observations)
      {false, generator} -> put_output_goal(generator, nil)
    end
  end

  # Achieving the last goal says nothing about wanting another; this is where
  # the hypothesis-testing schedule takes over from the base class's "be more
  # certain".
  defp need_new_output_goal?(%__MODULE__{} = generator, _ctx, true), do: {false, generator}

  defp need_new_output_goal?(%__MODULE__{} = generator, ctx, false),
    do: check_conditions_for_hypothesis_test(generator, ctx)

  @doc """
  Whether there is a good chance of separating the competing objects or poses.

  Returns the answer together with the generator, because deciding changes it:
  `focus_on_pose` is cleared at the start of every call, and the elapsed-steps
  branch grows `wait_factor`. Monty mutates both in place; a struct cannot.
  """
  @spec check_conditions_for_hypothesis_test(t(), Context.t()) :: {boolean(), t()}
  def check_conditions_for_hypothesis_test(%__MODULE__{} = generator, ctx) do
    lm = parent_lm(generator)
    elapsed = FeatureAtLocationBuffer.get_num_steps_post_output_goal_generated(buffer(generator))
    generator = %{generator | focus_on_pose: false}

    if waited_long_enough?(elapsed, generator) do
      decide_on_jump(generator, lm, ctx, elapsed)
    else
      {false, generator}
    end
  end

  # Monty's default is np.inf, meaning "never by patience": only a change in
  # what the module believes is worth jumping on.
  defp waited_long_enough?(_elapsed, %__MODULE__{min_post_goal_success_steps: :infinity}),
    do: false

  defp waited_long_enough?(elapsed, %__MODULE__{min_post_goal_success_steps: min}),
    do: elapsed > min

  defp decide_on_jump(generator, lm, ctx, elapsed) do
    {top_id, second_id} = EvidenceGraphLM.get_top_two_mlh_ids(lm)

    cond do
      # No hypothesis space anywhere: there is nothing to disambiguate.
      is_nil(top_id) and is_nil(second_id) ->
        {false, generator}

      # One object left: only its pose can still be in question.
      is_nil(second_id) ->
        focus_on_pose_if_poses_remain(generator, lm, top_id)

      true ->
        decide_between_objects(generator, lm, ctx, elapsed, top_id, second_id)
    end
  end

  defp decide_between_objects(generator, lm, ctx, elapsed, top_id, second_id) do
    top_mlh = EvidenceGraphLM.current_mlh(lm)
    base_threshold = EvidenceGraphLM.threshold_possible_matches(lm)

    smaller_threshold =
      EvidenceGraphLM.threshold_possible_matches(lm, generator.x_percent_scale_factor)

    cond do
      # One object is certain, or nearly so and the coin came up pose: stop
      # collecting identity evidence and pin the pose down.
      (length(smaller_threshold) == 1 and coin_flip(ctx) <= @pose_focus_probability) or
          length(base_threshold) == 1 ->
        focus_on_pose_if_poses_remain(generator, lm, top_id)

      top_two_changed?(generator.prev_top_mlhs, top_id, second_id) ->
        {true, generator}

      most_likely_pose_changed?(generator.prev_top_mlhs, top_mlh) ->
        {true, generator}

      rem(elapsed, generator.wait_factor * generator.elapsed_steps_factor) == 0 ->
        {true,
         %{generator | wait_factor: generator.wait_factor * generator.wait_growth_multiplier}}

      true ->
        {false, generator}
    end
  end

  # A single hypothesis has nothing to separate: the module knows which pose it
  # is looking from and no observation will change that.
  defp focus_on_pose_if_poses_remain(generator, lm, top_id) do
    if EvidenceGraphLM.num_hypotheses(lm, top_id) == 1 do
      {false, generator}
    else
      {true, %{generator | focus_on_pose: true}}
    end
  end

  # `np.all([previous ids] != [current ids])`: every id has to differ.
  defp top_two_changed?(nil, _top_id, _second_id), do: false

  defp top_two_changed?(
         [%{graph_id: previous_top}, %{graph_id: previous_second}],
         top_id,
         second_id
       ),
       do: previous_top != top_id and previous_second != second_id

  # `np.all(rotation.as_euler("xyz") != previous.as_euler("xyz"))`: all three
  # angles have to differ.
  defp most_likely_pose_changed?(nil, _top_mlh), do: false

  defp most_likely_pose_changed?([%{rotation: previous} | _rest], %{rotation: current}) do
    Rotation.to_euler_radians(current)
    |> Enum.zip(Rotation.to_euler_radians(previous))
    |> Enum.all?(fn {now, before} -> now != before end)
  end

  defp coin_flip(%Context{} = ctx) do
    {roll, _state} = :rand.uniform_s(Context.rng_for(ctx, :evidence_goal_generator))
    roll
  end

  # -- generating ----------------------------------------------------------

  defp generate_goal(%__MODULE__{} = generator, observations) do
    with {:ok, target_loc_id, generator} <- compute_graph_mismatch(generator),
         {:ok, target_info} <- target_loc_info(generator, target_loc_id),
         {:ok, goal} <- compute_goal_for_target_loc(generator, observations, target_info) do
      put_output_goal(generator, goal)
    else
      {:error, reason} ->
        Logger.warning("EvidenceGoalGenerator generated no goal: #{inspect(reason)}")
        put_output_goal(generator, nil)
    end
  end

  @doc """
  The node of the most likely object that the alternative explains worst.

  Both graphs are brought into the same frame first: the MLH's rotation is the
  rotation that would turn a displacement into the object's pose, so its inverse
  is the object's pose, and applying it puts the graph in environmental
  coordinates. The second object's stored rotation then does the opposite, so
  both graphs are expressed as they were learned and the comparison is between
  shapes rather than between placements.

  Returns the index into the *most likely* object's positions — the point to
  look at — and the generator, whose `prev_top_mlhs` now records what was
  compared, so the next step can notice if either changed.
  """
  @spec compute_graph_mismatch(t()) :: {:ok, non_neg_integer(), t()} | {:error, term()}
  def compute_graph_mismatch(%__MODULE__{} = generator) do
    lm = parent_lm(generator)

    with {:ok, channel} <-
           FeatureAtLocationBuffer.get_first_sensory_input_channel(buffer(generator)) do
      {top_id, second_id} = EvidenceGraphLM.get_top_two_mlh_ids(lm)
      top_mlh = EvidenceGraphLM.get_mlh_for_object(lm, top_id)
      second_mlh_object = EvidenceGraphLM.get_mlh_for_object(lm, second_id)

      # Comparing poses of one object means comparing its graph with itself: the
      # second candidate is then the second most likely pose, not an object.
      {second_id, second_mlh} =
        if generator.focus_on_pose do
          {_best_pose, second_pose} =
            EvidenceGraphLM.get_top_two_pose_hypotheses_for_graph_id(lm, top_id)

          {top_id, second_pose}
        else
          {second_id, second_mlh_object}
        end

      top_positions = positions(EvidenceGraphLM.get_graph(lm, top_id, channel), lm)
      second_graph = EvidenceGraphLM.get_graph(lm, second_id, channel)
      compared = into_frame(top_positions, top_mlh, second_mlh)

      distances =
        lm.graph_memory.object_model.find_nearest_neighbors(second_graph, compared, 1,
          distance: true
        )

      {:ok, farthest(distances), %{generator | prev_top_mlhs: [top_mlh, second_mlh_object]}}
    end
  end

  # The tops of each query's answers: one neighbour each, so the nearest node of
  # the second graph and how far away it is. Ties go to the earliest node, as
  # `np.argmax` does.
  defp farthest(distances) do
    distances
    |> Enum.map(fn [{distance, _id}] -> distance end)
    |> Enum.with_index()
    |> Enum.max_by(fn {distance, index} -> {distance, -index} end)
    |> elem(1)
  end

  # MLH frame -> environmental -> second candidate's learned frame. Monty
  # asserts that the transform sends the MLH's own location onto the second
  # candidate's; that is algebraically the identity, so it is not recomputed.
  defp into_frame(positions, top_mlh, second_mlh) do
    inverse = Rotation.invert(top_mlh.rotation)
    current_location = Rotation.apply(inverse, top_mlh.location)

    positions
    |> then(&Rotation.apply(inverse, &1))
    |> Enum.map(&SpatialArithmetics.subtract(&1, current_location))
    |> then(&Rotation.apply(second_mlh.rotation, &1))
    |> Enum.map(&SpatialArithmetics.add(&1, second_mlh.location))
  end

  @doc """
  Where the point to test is, on the most likely object's graph.

  Monty's `_get_target_loc_info`. The normal is the first three numbers of the
  node's `pose_vectors`, which is the surface normal the sensor has to face.
  """
  @spec target_loc_info(t(), non_neg_integer()) :: {:ok, target_info()} | {:error, term()}
  def target_loc_info(%__MODULE__{} = generator, target_loc_id) do
    lm = parent_lm(generator)

    with {:ok, channel} <-
           FeatureAtLocationBuffer.get_first_sensory_input_channel(buffer(generator)) do
      mlh = EvidenceGraphLM.current_mlh(lm)
      graph = EvidenceGraphLM.get_graph(lm, mlh.graph_id, channel)
      pose_vectors = lm.graph_memory.object_model.get_values_for_feature(graph, "pose_vectors")

      {:ok,
       %{
         hypothesis_to_test: mlh,
         target_loc: positions(graph, lm) |> Enum.at(target_loc_id),
         target_surface_normal: pose_vectors |> Enum.at(target_loc_id) |> Enum.take(3)
       }}
    end
  end

  @doc """
  A goal that puts the sensor above the target point, facing its surface.

  Monty's `_compute_goal_for_target_loc`. The displacement from the hypothesis's
  own location to the target is rotated out of the object's frame by the object
  pose, added to where the sensor is now, and then pushed off the surface along
  the (equally rotated) normal so that the sensor starts outside the object and
  looks down at it.

  The roll is left undefined, as in Monty: which way is up does not matter for
  telling two objects apart, and the policy that acts on this goal decides it.
  """
  @spec compute_goal_for_target_loc(t(), [Monty.Cmp.Message.t()], target_info()) ::
          {:ok, Goal.t()} | {:error, term()}
  def compute_goal_for_target_loc(%__MODULE__{} = generator, observations, target_info) do
    lm = parent_lm(generator)

    with {:ok, channel} <-
           FeatureAtLocationBuffer.get_first_sensory_input_channel(buffer(generator)),
         {:ok, sensory_input} <-
           CommunicationUtils.get_percept_from_channel(observations, channel) do
      goal_for(sensory_input, generator, lm, target_info)
    end
  end

  defp goal_for(sensory_input, generator, lm, target_info) do
    hypothesis = target_info.hypothesis_to_test

    # The MLH rotation turns a displacement into a pose, so the object's pose is
    # its inverse.
    object_rotation = Rotation.invert(hypothesis.rotation)

    displacement =
      SpatialArithmetics.subtract(target_info.target_loc, hypothesis.location)

    stand_off = generator.desired_object_distance * @stand_off_multiple

    proposed_surface_loc =
      sensory_input.location
      |> SpatialArithmetics.add(Rotation.apply(object_rotation, displacement))

    surface_normal = Rotation.apply(object_rotation, target_info.target_surface_normal)

    target_loc =
      SpatialArithmetics.add(
        proposed_surface_loc,
        SpatialArithmetics.scale(surface_normal, stand_off)
      )

    Goal.new(%{
      location: target_loc,
      morphological_features: %{
        # A gaze goal has one direction and no frame around it, which is what
        # makes it impossible to rotate — as in Monty.
        "pose_vectors" => %GazeDirection{
          value: [
            SpatialArithmetics.scale(surface_normal, -1.0),
            [nil, nil, nil],
            [nil, nil, nil]
          ]
        },
        "pose_fully_defined" => nil,
        "on_object" => 1
      },
      non_morphological_features: nil,
      confidence: confidence_of(lm),
      pass_message: true,
      sender_id: lm.learning_module_id,
      sender_type: :gsg,
      process_features_in_lm: true,
      goal_tolerances: nil,
      # `achieved` and `matching_step_when_output_goal_set` are filled in on the
      # next step, so they start empty rather than guessed.
      info: %{
        "proposed_surface_loc" => proposed_surface_loc,
        "hypothesis_to_test" => hypothesis,
        "achieved" => nil,
        "matching_step_when_output_goal_set" => nil
      }
    })
  end

  defp put_output_goal(%__MODULE__{} = generator, goal),
    do: %{generator | base: %{generator.base | output_goal: goal}}

  defp buffer(%__MODULE__{} = generator), do: GraphGoalGenerator.buffer(generator.base)

  defp positions(model, lm), do: lm.graph_memory.object_model.positions(model)

  # How sure the module is of the hypothesis the goal is based on: a goal built
  # on a guess should weigh less than one built on a conviction.
  defp confidence_of(lm) do
    {output, _lm} = EvidenceGraphLM.get_output(lm)
    output.confidence
  end

  @doc "The statistics this generator keeps on its parent's buffer."
  @spec goal_stat_keys() :: [String.t()]
  def goal_stat_keys, do: GraphGoalGenerator.goal_stat_keys()
end
