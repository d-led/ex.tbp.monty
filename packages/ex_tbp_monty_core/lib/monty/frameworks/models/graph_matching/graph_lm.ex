defmodule Monty.Frameworks.Models.GraphMatching.GraphLM do
  @moduledoc """
  A learning module whose memory is a graph of what it has seen.

  Mirrors `tbp/monty/frameworks/models/graph_matching.py::GraphLM`, the class
  `DisplacementGraphLM`, `FeatureGraphLM` and `EvidenceGraphLM` are all built on
  in Monty. It is the part they share: a buffer of what this episode has seen, a
  `GraphMemory` of what past episodes left, and the bookkeeping that turns one
  into the other — which graphs are possible, where on the object the sensor is,
  and which objects a graph was built from.

  What it does **not** decide is how a possible match is narrowed; that is
  `compute_possible_matches/4`, which every subclass in Monty overrides. In Monty
  it is a private method called on `self`, and the subclass's version replaces it.
  A module here composes instead of inheriting (`docs/monty-differences.md`
  §2.9), so the same function is public and takes the module it works on.

  ## Why the fields are the module's

  Monty's `__init__` sets them and its methods read them, so they are the state
  this module *is*: the buffer, the memory, the possible matches and their paths,
  the object this episode is about, and what the module concluded. A class that
  composes this one keeps the same shape, which is why `LoggingUtils` can read an
  episode's statistics off either.

  ## Where it deliberately differs

    * **`get_unique_pose_if_available/2` raises.** Monty raises
      `NotImplementedError`: a graph module cannot say where the object is
      without a matching scheme, and a subclass supplies one. A silent `nil`
      would read as "no pose yet", which is a different answer.
    * **Errors are values, not exceptions.** A percept set with no sensor
      location does not raise out of a step: `add_displacements/2` answers
      `{:error, :no_sensor_module_location}`, which the caller turns into a step
      that changed nothing.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule


  alias Monty.Cmp
  alias Monty.Cmp.{AttentionRegion, Message}
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.GoalGeneration.GraphGoalGenerator
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Geometry.Rotation

  @default_learning_module_id "LM_0"

  @enforce_keys [:buffer, :graph_memory]
  defstruct [
    :buffer,
    :graph_memory,
    learning_module_id: @default_learning_module_id,
    gsg: nil,
    mode: nil,
    target_to_graph_id: %{},
    graph_id_to_target: %{},
    primary_target: nil,
    primary_target_rotation_quat: nil,
    possible_matches: %{},
    possible_paths: %{},
    tolerances: %{},
    has_detailed_logger: false,
    symmetry_evidence: 0,
    goals: [],
    terminal_state: nil,
    detected_object: nil,
    detected_pose: nil,
    detected_rotation_r: nil,
    stepwise_target_object: nil,
    stepwise_targets_list: []
  ]

  @type graph_id :: String.t()
  @type input_channel :: String.t()
  @type terminal_state :: :match | :no_match | :time_out | :pose_time_out | nil
  # A pose as a recognition reports it: where, which way, and how large.
  @type pose :: [float()]

  @type t :: %__MODULE__{}

  @doc """
  A module over an empty memory, with its own goal generator.

  Options are Monty's `__init__` arguments plus the two this port's modules all
  take: `:learning_module_id` (Monty's default is `"LM_0"`, and a config's id
  replaces it), `:tolerances` (what a feature has to match within, by input
  channel), `:has_detailed_logger`, and `:gsg` — a goal generator, built per
  module because it holds a copy of the module it points at.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    lm = %__MODULE__{
      buffer: FeatureAtLocationBuffer.new(),
      graph_memory:
        Keyword.get_lazy(options, :graph_memory, fn ->
          GraphMemory.new(k: nil, graph_delta_thresholds: nil)
        end),
      learning_module_id: Keyword.get(options, :learning_module_id, @default_learning_module_id),
      tolerances: Keyword.get(options, :tolerances, %{}),
      has_detailed_logger: Keyword.get(options, :has_detailed_logger, false)
    }

    lm = init_graph_lm(lm)

    case Keyword.get(options, :gsg, GraphGoalGenerator.new()) do
      nil -> lm
      gsg -> %{lm | gsg: gsg.__struct__.point_at(gsg, lm)}
    end
  end

  # Monty's `_init_GraphLM`: everything an episode leaves behind. `reset_stm/1`
  # runs it, and a module that just ended an episode is exactly a module with
  # these fields empty.
  defp init_graph_lm(%__MODULE__{} = lm) do
    %{
      lm
      | goals: [],
        terminal_state: nil,
        detected_object: nil,
        detected_pose: nil,
        detected_rotation_r: nil
    }
  end

  @doc """
  Monty's `init_from_ltm`: the hypotheses the memory already supports.

  `GraphMemory.get_initial_hypotheses/1` answers every object it holds and no
  paths — there is nothing to be possible about until an observation arrives.
  """
  @spec init_from_ltm(t()) :: t()
  def init_from_ltm(%__MODULE__{} = lm) do
    {possible_matches, possible_paths} = GraphMemory.get_initial_hypotheses(lm.graph_memory)
    %{lm | possible_matches: possible_matches, possible_paths: possible_paths}
  end

  @doc "Monty's `reset_stm`: forget the episode, keep what was learned."
  @impl true
  @spec reset_stm(t()) :: t()
  def reset_stm(%__MODULE__{} = lm) do
    lm
    |> init_from_ltm()
    |> Map.put(:buffer, FeatureAtLocationBuffer.reset(lm.buffer))
    |> reset_goal_generator()
    |> init_graph_lm()
  end

  @doc """
  Monty's `GraphLM(**config)`: a module that learns by being told, and does not
  match.

  The base class is buildable in Monty — `graph_1lm.yaml` names it, and a
  supervised pretraining run builds it and trains with it, because a supervised
  episode is handed the object and pose it saw and never asks the module to
  narrow anything. What the base class cannot do it does *not* do: `_compute_possible_matches`
  raises `NotImplementedError` upstream, and `compute_possible_matches/4` here
  answers `{:error, :not_implemented}` — which is where a config that evaluates
  with this module finds out, instead of at its second step.

  Refusing to build it was this port saying more than Monty does: it turned a
  module that trains perfectly well into a configuration nobody could run.
  """
  @spec from_config(map(), keyword()) :: {:ok, t()}
  def from_config(config, options \\ []) when is_map(config) do
    {:ok,
     new(
       graph_memory: memory(options),
       tolerances: Map.get(config, "tolerances", %{}),
       learning_module_id: Map.get(config, "learning_module_id", @default_learning_module_id),
       has_detailed_logger: Keyword.get(options, :has_detailed_logger, false)
     )}
  end

  # A memory handed in is what the module starts from — a pretrained library, or
  # the one the last episode of the phase wrote. With none it starts empty, and
  # `k` stays whatever the config said rather than being defaulted here.
  defp memory(options) do
    case Keyword.get(options, :memory) do
      %GraphMemory{} = memory -> memory
      _none -> GraphMemory.new(k: nil, graph_delta_thresholds: nil)
    end
  end

  defp reset_goal_generator(%__MODULE__{gsg: nil} = lm), do: lm

  defp reset_goal_generator(%__MODULE__{} = lm),
    do: %{lm | gsg: lm.gsg.__struct__.reset(lm.gsg)}

  @doc """
  Monty's `fixme_reset_ground_truth`: the object this episode is about.

  Named "fixme" upstream because a learning module cannot work the object out;
  the experiment knows it and passes it in. A `nil` target leaves the one this
  module already had, which is what an episode of a run without resetting
  boundaries relies on.
  """
  @impl true
  @spec set_target(t(), map() | nil) :: t()
  def set_target(%__MODULE__{} = lm, nil) do
    %{lm | stepwise_target_object: nil, stepwise_targets_list: []}
  end

  def set_target(%__MODULE__{} = lm, primary_target) do
    %{
      lm
      | primary_target: primary_target["object_name"],
        primary_target_rotation_quat: primary_target["quat_rotation"],
        stepwise_target_object: nil,
        stepwise_targets_list: []
    }
  end

  # -- supervision ----------------------------------------------------------

  @doc """
  Monty's `_pass_target_info_to_model`: the conclusion an experiment states.

  A pretraining experiment does not match. It knows which object it put in front
  of the agent, so the episode's answer is that knowledge rather than something
  the module worked out — and the six numbers a matching episode would have
  concluded for itself (where on the model, where the sensor was, the turn, the
  scale) are the ones it is told instead.

  `location_on_model` is the object's place in the world the *first* time this
  experiment showed it, not this episode's: a later epoch may place the object
  somewhere else, and the graph must stay where it was learned. That map is
  Monty's `first_epoch_object_location`.
  """
  @spec supervise(t(), map(), [number()]) :: t()
  def supervise(%__MODULE__{} = lm, target, location_on_model) do
    {:ok, rotation} = Rotation.from_quaternion(quaternion(target))

    stats = %{
      "possible_matches" => [target["object_name"]],
      "detected_location_on_model" => location_on_model,
      "detected_location_rel_body" => target["position"],
      "detected_rotation" => target["euler_rotation"],
      "detected_scale" => target["scale"]
    }

    %{
      lm
      | detected_object: target["object_name"],
        detected_rotation_r: Rotation.invert(rotation),
        buffer: FeatureAtLocationBuffer.add_overall_stats(lm.buffer, stats)
    }
  end

  # Monty's target carries the object's turn under two names; `quat_rotation` is
  # the `wxyz` one a rotation is built from. A target without it cannot
  # supervise anything, and failing here says which object it was.
  defp quaternion(%{"quat_rotation" => [w, x, y, z]}), do: {w, x, y, z}

  defp quaternion(target) do
    raise ArgumentError,
          "a supervised episode needs the target's quat_rotation, and " <>
            "#{inspect(target["object_name"])} has none"
  end

  @doc """
  Monty's wipe for a module the experiment does not supervise.

  Such a module matched on its own during the episode, so what it concluded is a
  guess — and a guess written into memory is worse than nothing learned.
  `detected_object` is what gates the write, so clearing it is the whole
  decision; the hypotheses go with it so that the episode's statistics do not
  claim a match nobody made.
  """
  @spec clear_hypotheses(t()) :: t()
  def clear_hypotheses(%__MODULE__{} = lm) do
    cleared = %{
      "detected_location_on_model" => nil,
      "detected_location_rel_body" => nil,
      "detected_rotation" => nil,
      "detected_scale" => nil
    }

    %{
      lm
      | possible_matches: %{},
        possible_paths: %{},
        detected_object: nil,
        detected_pose: nil,
        detected_rotation_r: nil,
        buffer: FeatureAtLocationBuffer.add_overall_stats(lm.buffer, cleared)
    }
  end

  # -- stepping -------------------------------------------------------------

  @doc """
  Monty's `matching_step`: what the observation makes possible, and what it does
  not.

  A location-only step is nothing to match on and returns the module unchanged;
  a step with features narrows the possible matches, concludes `:no_match` when
  nothing is left, steps the goal generator and records the step's statistics.
  """
  @impl true
  @spec matching_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()}
  def matching_step(percepts, ctx, %__MODULE__{} = lm),
    do: matching_step(percepts, ctx, lm, &compute_possible_matches/4)

  @doc """
  The same, narrowing with `narrow` rather than with this class's own scheme.

  A matching scheme is what `DisplacementGraphLM`, `FeatureGraphLM` and the
  evidence module each supply, so it is a callback here for the same reason the
  pose is: Monty inherits the method and overrides it, and a class that
  composes must be able to name what it composes.
  """
  @spec matching_step(
          [Message.t()],
          Monty.Context.t(),
          t(),
          (t(), Monty.Context.t(), [Message.t()], boolean() -> {:ok, t()} | {:error, term()})
        ) :: {:ok, t()}
  def matching_step(percepts, ctx, %__MODULE__{} = lm, narrow) do
    if Monty.Runtime.location_only_step?(percepts) do
      {:ok, lm}
    else
      first_movement_detected? = agent_moved_since_reset?(lm)
      feature_percepts = Enum.filter(percepts, & &1.process_features_in_lm)
      log_not_moved(lm, first_movement_detected?)

      case add_displacements(lm, percepts) do
        {:error, _reason} ->
          {:ok, lm}

        {:ok, displaced} ->
          displaced
          |> buffer_percepts(lm)
          |> narrow_and_conclude(ctx, narrow, feature_percepts, first_movement_detected?)
      end
    end
  end

  # Monty logs it and matches anyway: the first step of an episode has nothing
  # behind it to have moved from, which is a zero displacement rather than a
  # reason not to look.
  defp log_not_moved(_lm, true), do: :ok
  defp log_not_moved(lm, false),
    do: Monty.Trace.trace("#{lm.learning_module_id} has not moved yet")

  # The observation goes into the buffer twice, as Monty writes it: once as the
  # step's own percepts, and once per displaced percept as what this module is
  # matching against.
  #
  # `append/2` refuses a step with no sensor-module location — the same
  # observation `add_displacements/2` has just refused, so a step that reaches
  # here has one, and reading the buffer out of the result is what this row is
  # allowed to assume.
  @doc """
  The step's percepts, in the buffer — twice, as Monty writes them.

  Once as the step's own percepts, which is what a memory update reads later,
  and once per displaced percept as what this module matched against. A class
  that composes this one runs this after its own displacement is set.
  """
  @spec buffer_percepts([Message.t()], t()) :: t()
  def buffer_percepts(percepts, %__MODULE__{} = lm) do
    {:ok, buffer} = FeatureAtLocationBuffer.append(lm.buffer, percepts)
    lm = %{lm | buffer: buffer}

    Enum.reduce(percepts, lm, fn percept, lm ->
      %{lm | buffer: FeatureAtLocationBuffer.append_input_percepts(lm.buffer, percept)}
    end)
  end

  defp narrow_and_conclude(lm, ctx, narrow, feature_percepts, first_movement_detected?) do
    case narrow.(lm, ctx, feature_percepts, first_movement_detected?) do
      {:ok, lm} ->
        {:ok, lm |> concluded() |> step_goal_generator(ctx, feature_percepts) |> record_stats()}

      {:error, :not_implemented} ->
        raise "#{lm.learning_module_id} is a bare GraphLM, which has no matching " <>
                "scheme to narrow possible matches with; a subclass supplies one"
    end
  end

  # A narrowing that leaves nothing possible is this episode's answer: Monty
  # names the module `:no_match` rather than reporting an empty hypothesis space.
  defp concluded(lm) do
    if get_possible_matches(lm) == [], do: set_individual_ts(lm, :no_match), else: lm
  end

  @doc "Monty's `exploratory_step`: buffer the observation, learn nothing yet."
  @impl true
  @spec exploratory_step([Message.t()], Monty.Context.t(), t()) :: {:ok, t()}
  def exploratory_step(percepts, _ctx, %__MODULE__{} = lm) do
    if Monty.Runtime.location_only_step?(percepts) do
      {:ok, lm}
    else
      case add_displacements(lm, percepts) do
        {:ok, displaced} -> {:ok, buffer_percepts(displaced, lm)}
        {:error, _reason} -> {:ok, lm}
      end
    end
  end

  @doc """
  Monty's `_compute_possible_matches`: which observations are still possible.

  The base class has nothing to say — Monty raises `NotImplementedError`, and
  every subclass in the tree answers this instead. The answer is an error rather
  than a guess because a graph module with no matching scheme would narrow
  nothing and look like one that had not decided yet.
  """
  @spec compute_possible_matches(t(), Monty.Context.t(), [Message.t()], boolean()) ::
          {:error, :not_implemented}
  def compute_possible_matches(
        %__MODULE__{} = _lm,
        _ctx,
        _observations,
        _first_movement_detected?
      ) do
    {:error, :not_implemented}
  end

  # -- long-term memory -----------------------------------------------------

  @doc """
  Monty's `update_ltm_from_stm`: a training episode's observations, into memory.

  An evaluation episode learns nothing, and an episode that saw nothing has
  nothing to write — which is what keeps `detected_object` the gate on both.
  """
  @impl true
  @spec update_ltm_from_stm(t()) :: t()
  def update_ltm_from_stm(%__MODULE__{mode: :train} = lm) do
    if FeatureAtLocationBuffer.size(lm.buffer) > 0 do
      Monty.Trace.trace("\n---Updating memory of #{lm.learning_module_id}---")
      update_memory(lm)
    else
      lm
    end
  end

  def update_ltm_from_stm(%__MODULE__{} = lm), do: lm

  @doc "Monty's `fixme_update_ground_truth`: which objects the graph was built from."
  @impl true
  @spec fixme_update_ground_truth(t()) :: t()
  def fixme_update_ground_truth(%__MODULE__{mode: :train} = lm) do
    if FeatureAtLocationBuffer.size(lm.buffer) > 0 do
      update_target_graph_mapping(lm, lm.detected_object, lm.primary_target)
    else
      lm
    end
  end

  def fixme_update_ground_truth(%__MODULE__{} = lm), do: lm

  # Monty's `_update_memory`: every buffered observation, and the pose the
  # episode concluded, handed to the memory to decide whether it extends a graph
  # or builds one.
  defp update_memory(%__MODULE__{} = lm) do
    infos = FeatureAtLocationBuffer.get_infos_for_graph_update(lm.buffer)

    memory =
      GraphMemory.update_memory(
        lm.graph_memory,
        infos.locations,
        infos.features,
        lm.detected_object,
        infos.object_location_rel_body,
        infos.location_rel_model,
        model_rotation(lm.detected_rotation_r)
      )

    %{lm | graph_memory: memory}
  end

  # The pose the module reports is the object's in the world; the memory stores
  # observations in the object's own frame, so what it is given is the inverse.
  defp model_rotation(nil), do: nil
  defp model_rotation(%Rotation{} = rotation), do: Rotation.invert(rotation)

  # Monty's `_update_target_graph_mapping`: two dicts, kept as sets, so a graph
  # built from two objects that look alike says so.
  defp update_target_graph_mapping(%__MODULE__{} = lm, nil, _target_object), do: lm

  defp update_target_graph_mapping(%__MODULE__{} = lm, detected_object, target_object) do
    graph_id_to_target =
      Map.update(
        lm.graph_id_to_target,
        detected_object,
        MapSet.new([target_object]),
        fn targets ->
          MapSet.put(targets, target_object)
        end
      )

    target_to_graph_id =
      Map.update(lm.target_to_graph_id, target_object, MapSet.new([detected_object]), fn graphs ->
        MapSet.put(graphs, detected_object)
      end)

    %{lm | graph_id_to_target: graph_id_to_target, target_to_graph_id: target_to_graph_id}
  end

  # -- the vote -------------------------------------------------------------

  @doc """
  Monty's `send_out_vote`: the objects this module knows this one is not.

  A negative vote, so two modules on one object need not know the same objects:
  what one rules out, the other need not check.
  """
  @impl true
  @spec send_out_vote(t()) :: {term(), t()}
  def send_out_vote(%__MODULE__{} = lm) do
    possible = MapSet.new(get_possible_matches(lm))
    known = MapSet.new(get_all_known_object_ids(lm))

    {MapSet.difference(known, possible), lm}
  end

  @doc """
  Monty's `receive_votes`: another module ruling an object out.

  A module that has not been on the object this episode has no hypothesis to
  remove, and joining a vote against an object it never considered would be a
  conclusion it did not reach.
  """
  @impl true
  @spec receive_votes(term(), t()) :: {:ok, t()}
  def receive_votes(votes, %__MODULE__{} = lm) do
    if votes in [nil, []] or
         FeatureAtLocationBuffer.get_num_observations_on_object(lm.buffer) == 0 do
      {:ok, lm}
    else
      possible_matches =
        Enum.reduce(votes, lm.possible_matches, fn vote, possible_matches ->
          Map.delete(possible_matches, vote)
        end)

      {:ok, add_votes_to_buffer_stats(%{lm | possible_matches: possible_matches}, votes)}
    end
  end

  # -- what the model asks --------------------------------------------------

  @doc "Monty's `get_output`: only an evidence module has a hypothesis to publish."
  @impl true
  @spec get_output(t()) :: {nil, t()}
  def get_output(%__MODULE__{} = lm), do: {nil, lm}

  @doc """
  Monty's `propose_goals`: what the goal generator last asked for.

  Only after a step the module processed, so a sensor that has moved without
  looking does not redirect the agent.
  """
  @impl true
  @spec propose_goals(t()) :: {[Monty.Cmp.Goal.t()], t()}
  def propose_goals(%__MODULE__{gsg: nil} = lm), do: {[], %{lm | goals: []}}

  def propose_goals(%__MODULE__{} = lm) do
    goals =
      if FeatureAtLocationBuffer.get_last_obs_processed(lm.buffer),
        do: lm.gsg.__struct__.output_goals(lm.gsg),
        else: []

    {goals, %{lm | goals: goals}}
  end

  @doc "Monty's `propose_region`: the region its goals are in."
  @impl true
  @spec propose_region(t()) :: {AttentionRegion.t(), t()}
  def propose_region(%__MODULE__{goals: []} = lm), do: {AttentionRegion.empty(), lm}

  def propose_region(%__MODULE__{} = lm) do
    locations = Enum.map(lm.goals, & &1.location)
    {AttentionRegion.uniform(locations, AttentionRegion.max_weight()), lm}
  end

  @doc """
  Monty's `update_terminal_condition`: has this module concluded?

  Three answers, in Monty's order: nothing possible is `:no_match` (and the
  place the buffer last held is where it was); exactly one possible object with
  a unique pose is `:match`; anything else is not a conclusion, and a previous
  `:match` is withdrawn because the evidence no longer says it.
  """
  @impl true
  @spec update_terminal_condition(t()) :: {t(), terminal_state()}
  def update_terminal_condition(%__MODULE__{} = lm),
    do: update_terminal_condition(lm, &get_unique_pose_if_available/2)

  @doc """
  The same, asking `pose_of` whether it can narrow the pose.

  A matching scheme is what turns a possible path into a pose, so the question
  is a callback rather than a method: `DisplacementGraphLM` and the evidence
  module each answer it, and `GraphLM` on its own cannot.
  """
  @spec update_terminal_condition(t(), (t(), graph_id() -> pose() | nil)) ::
          {t(), terminal_state()}
  def update_terminal_condition(%__MODULE__{} = lm, pose_of) do
    possible_matches = get_possible_matches(lm)
    observations? = FeatureAtLocationBuffer.get_num_observations_on_object(lm.buffer) > 0

    cond do
      # Nothing possible, which is this episode's answer whatever the pose would
      # have been: Monty records where the sensor last held, then concludes.
      possible_matches == [] ->
        lm =
          if observations? do
            %{
              lm
              | buffer:
                  FeatureAtLocationBuffer.update_stats(lm.buffer, %{
                    "detected_location_rel_body" =>
                      FeatureAtLocationBuffer.current_location(lm.buffer)
                  })
            }
          else
            lm
          end

        lm = set_individual_ts(lm, :no_match)

        {lm, lm.terminal_state}

      observations? and length(possible_matches) == 1 ->
        object_id = hd(possible_matches)

        case pose_of.(lm, object_id) do
          nil ->
            # A match already made is withdrawn: the pose that came with it is no
            # longer the only one possible.
            lm = if lm.terminal_state == :match, do: set_individual_ts(lm, nil), else: lm

            Monty.Trace.trace("Pose for #{lm.learning_module_id} not narrowed down yet")

            {lm, lm.terminal_state}

          _pose ->
            lm = set_individual_ts(lm, :match)
            Monty.Trace.trace("#{lm.learning_module_id} recognized object #{object_id}")
            {lm, lm.terminal_state}
        end

      true ->
        lm = if lm.terminal_state == :match, do: set_individual_ts(lm, nil), else: lm
        Monty.Trace.trace("#{lm.learning_module_id} did not recognize an object yet.")
        {lm, lm.terminal_state}
    end
  end

  # -- getters --------------------------------------------------------------

  @doc "Monty's `get_possible_matches`: the objects still in the running."
  @spec get_possible_matches(t()) :: [graph_id()]
  def get_possible_matches(%__MODULE__{} = lm), do: Map.keys(lm.possible_matches)

  @doc "Monty's `get_possible_paths`, for a log or a plot."
  @spec get_possible_paths(t()) :: %{optional(graph_id()) => term()}
  def get_possible_paths(%__MODULE__{} = lm), do: lm.possible_paths

  @doc "Monty's `get_object_scale`: no scale detection, so the object is as stored."
  @spec get_object_scale(t(), graph_id()) :: 1
  def get_object_scale(%__MODULE__{}, _object_id), do: 1

  @doc "Monty's `get_all_known_object_ids`: everything this module's memory holds."
  @spec get_all_known_object_ids(t()) :: [graph_id()]
  def get_all_known_object_ids(%__MODULE__{} = lm),
    do: GraphMemory.get_memory_ids(lm.graph_memory)

  @doc "Monty's `get_graph`: one object's graph in one input channel."
  @spec get_graph(t(), graph_id(), input_channel() | nil) :: term()
  def get_graph(%__MODULE__{} = lm, model_id, input_channel \\ nil),
    do: GraphMemory.get_graph(lm.graph_memory, model_id, input_channel)

  @doc "Monty's `get_input_channels_in_graph`."
  @spec get_input_channels_in_graph(t(), graph_id()) :: [input_channel()]
  def get_input_channels_in_graph(%__MODULE__{} = lm, model_id),
    do: GraphMemory.get_input_channels_in_graph(lm.graph_memory, model_id)

  @doc """
  Monty's `get_unique_pose_if_available`: the subclass's to answer.

  A graph module on its own has no matching scheme, so there is nothing to turn
  a possible path into a pose with. Two answers are honest: no path means no
  pose yet, and a path only a subclass can read means the class is incomplete —
  which is said out loud rather than answered with "not yet", because the model
  reads that as an episode that has not finished.
  """
  @spec get_unique_pose_if_available(t(), graph_id()) :: nil
  def get_unique_pose_if_available(%__MODULE__{possible_paths: paths}, object_id) do
    case Map.get(paths, object_id) do
      nil ->
        nil

      _possible_paths ->
        raise "GraphLM.get_unique_pose_if_available/2 is the subclass's to implement"
    end
  end

  # -- conclusions ----------------------------------------------------------

  @doc """
  Monty's `set_detected_object`: what a conclusion says the module was looking at.

  A conclusion that is not a recognition names a new object — `new_object<n>` —
  which is what makes unsupervised learning possible: a training episode that
  matched nothing still learned something, and it becomes the next graph.
  """
  @spec set_detected_object(t(), terminal_state()) :: t()
  def set_detected_object(%__MODULE__{} = lm, terminal_state) do
    %{lm | terminal_state: terminal_state, detected_object: detected_object(lm, terminal_state)}
  end

  defp detected_object(%__MODULE__{}, nil), do: nil

  defp detected_object(%__MODULE__{} = lm, terminal_state)
       when terminal_state == :no_match or lm.possible_matches == %{} do
    "new_object#{GraphMemory.size(lm.graph_memory)}"
  end

  defp detected_object(%__MODULE__{} = lm, :match), do: hd(get_possible_matches(lm))

  defp detected_object(%__MODULE__{}, _terminal_state), do: nil

  @doc """
  Monty's `set_individual_ts`: conclude, and record the pose if it was a match.

  The buffer keeps the first conclusion only — an episode ends once, and the
  first ending is the one that mattered.
  """
  @spec set_individual_ts(t(), terminal_state()) :: t()
  def set_individual_ts(%__MODULE__{} = lm, terminal_state) do
    Monty.Trace.trace("Setting terminal state of #{lm.learning_module_id} to #{terminal_state}")
    lm = set_detected_object(lm, terminal_state)

    buffer =
      if terminal_state == :match,
        do:
          FeatureAtLocationBuffer.set_individual_ts(
            lm.buffer,
            lm.detected_object,
            lm.detected_pose
          ),
        else: FeatureAtLocationBuffer.set_individual_ts(lm.buffer, nil, nil)

    %{lm | buffer: buffer}
  end

  @doc "Monty's `set_experiment_mode`: whether this episode trains or evaluates."
  @impl true
  @spec set_experiment_mode(
          t(),
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
        ) ::
          t()
  def set_experiment_mode(%__MODULE__{} = lm, mode), do: %{lm | mode: mode}

  @doc "What this module concluded, as the model reads it."
  @impl true
  @spec conclusion(t()) :: terminal_state()
  def conclusion(%__MODULE__{} = lm), do: lm.terminal_state

  @doc "Whether the last buffered observation was one this module processed."
  @impl true
  @spec observation_processed?(t()) :: boolean()
  def observation_processed?(%__MODULE__{} = lm),
    do: FeatureAtLocationBuffer.get_last_obs_processed(lm.buffer)

  @doc "Records which object the module's sensor is on this step."
  @impl true
  @spec set_stepwise_target(t(), String.t() | nil) :: t()
  def set_stepwise_target(%__MODULE__{} = lm, label), do: %{lm | stepwise_target_object: label}

  @doc """
  Sets the conclusion without deciding one.

  Monty's `_set_terminal_state`, which a run without episode boundaries uses to
  forget a conclusion it no longer stands by.
  """
  @impl true
  @spec set_terminal_state(t(), terminal_state()) :: t()
  def set_terminal_state(%__MODULE__{} = lm, terminal_state),
    do: set_detected_object(lm, terminal_state)

  @doc "The long-term memory this module holds."
  @impl true
  @spec graph_memory(t()) :: GraphMemory.t() | :none
  def graph_memory(%__MODULE__{} = lm), do: lm.graph_memory

  # -- statistics -----------------------------------------------------------

  @doc "Monty's `collect_stats_to_save`: what this step is worth logging."
  @spec collect_stats_to_save(t()) :: {t(), map()}
  def collect_stats_to_save(%__MODULE__{} = lm) do
    stats = %{"possible_matches" => get_possible_matches(lm)}

    {lm, if(lm.has_detailed_logger, do: add_detailed_stats(lm, stats), else: stats)}
  end

  @doc "Monty's `_add_detailed_stats`: nothing extra here; subclasses add their own."
  @spec add_detailed_stats(t(), map()) :: map()
  def add_detailed_stats(%__MODULE__{}, stats), do: stats

  @doc "Monty's `add_lm_processing_to_buffer_stats`."
  @impl true
  @spec add_lm_processing_to_buffer_stats(t(), boolean()) :: t()
  def add_lm_processing_to_buffer_stats(%__MODULE__{} = lm, lm_processed) do
    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.update_stats(
            lm.buffer,
            %{"lm_processed_steps" => lm_processed},
            update_time: false
          )
    }
  end

  @doc """
  Monty's `state_dict`: the memory, and which objects it was built from.

  Not the buffer: what an episode saw is over, and what a later one needs is
  what it left.
  """
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = lm) do
    %{
      graph_memory: GraphMemory.state_dict(lm.graph_memory),
      target_to_graph_id: lm.target_to_graph_id,
      graph_id_to_target: lm.graph_id_to_target,
      has_detailed_logger: lm.has_detailed_logger
    }
  end

  @doc "Monty's `load_state_dict`: a memory, and the module state that follows it."
  @spec load_state_dict(t(), map()) :: t()
  def load_state_dict(%__MODULE__{} = lm, memo) do
    lm
    |> Map.put(:graph_memory, GraphMemory.load_state_dict(lm.graph_memory, memo.graph_memory))
    |> Map.put(:target_to_graph_id, memo.target_to_graph_id)
    |> Map.put(:graph_id_to_target, memo.graph_id_to_target)
    |> Map.put(:has_detailed_logger, Map.get(memo, :has_detailed_logger, lm.has_detailed_logger))
    |> init_from_ltm()
  end

  # -- helpers --------------------------------------------------------------

  @doc """
  Monty's `_agent_moved_since_reset`: whether the buffer has anything in it.

  A module that has buffered nothing has not moved, and its first observation
  is the place the displacements start from.
  """
  @spec agent_moved_since_reset?(t()) :: boolean()
  def agent_moved_since_reset?(%__MODULE__{} = lm),
    do: FeatureAtLocationBuffer.size(lm.buffer) > 0

  @doc """
  Monty's `_add_displacements`: how far the sensor moved since the last percept.

  One displacement, from the mean of the sensor modules' locations, set on every
  percept — a learning module's own output moves with the sensor that produced
  it. The first step of an episode is a zero displacement, which is what makes
  the first observation a starting point rather than a move.
  """
  @spec add_displacements(t(), [Message.t()]) :: {:ok, [Message.t()]} | {:error, term()}
  def add_displacements(%__MODULE__{} = lm, percepts) do
    sensor_module_percepts = Enum.filter(percepts, &Message.from_sensor_module?/1)

    case Cmp.location_mean(sensor_module_percepts) do
      nil ->
        {:error, :no_sensor_module_location}

      location ->
        displacement =
          case lm.buffer.last_location do
            nil ->
              [0.0, 0.0, 0.0]

            last_location ->
              Enum.zip_with([location, last_location], fn [now, then] -> now - then end)
          end

        {:ok, Enum.map(percepts, &Message.set_displacement(&1, displacement))}
    end
  end

  @doc """
  Monty's `_select_features_to_use`: the features this module matches on.

  A feature is matchable when the module has a tolerance for it, and
  `pose_fully_defined` is always carried because a pose that is not defined
  changes how the pose it came with may be read.
  """
  @spec select_features_to_use(t(), [Message.t()]) :: %{optional(input_channel()) => map()}
  def select_features_to_use(%__MODULE__{} = lm, percepts) do
    Map.new(percepts, fn percept ->
      tolerances = Map.get(lm.tolerances, percept.sender_id, %{})

      morphological =
        for {name, value} <- percept.morphological_features,
            matchable?(name, tolerances),
            into: %{},
            do: {name, value}

      non_morphological =
        for {name, value} <- percept.non_morphological_features || %{},
            matchable?(name, tolerances),
            into: %{},
            do: {name, value}

      {percept.sender_id, Map.merge(morphological, non_morphological)}
    end)
  end

  defp matchable?(name, tolerances),
    do: Map.has_key?(tolerances, name) or name == "pose_fully_defined"

  # Monty's `_add_votes_to_buffer_stats`, whose own comment calls it
  # bookkeeping a paper does not read; it is recorded and nothing acts on it.
  defp add_votes_to_buffer_stats(%__MODULE__{} = lm, votes) do
    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.update_stats(lm.buffer, %{"vote" => votes}, update_time: false)
    }
  end

  # The generator is a copy that belongs to the module, so it is handed the
  # module it now points at before it is stepped.
  @doc """
  One step of the goal generator, pointed at the module it now belongs to.

  A class that composes this one runs the generator itself, because its own
  fields are what the generator was told about.
  """
  @spec step_goal_generator(t(), Monty.Context.t(), [Message.t()]) :: t()
  def step_goal_generator(%__MODULE__{gsg: nil} = lm, _ctx, _percepts), do: lm

  def step_goal_generator(%__MODULE__{} = lm, ctx, percepts) do
    gsg = lm.gsg.__struct__.point_at(lm.gsg, lm)
    %{lm | gsg: gsg.__struct__.step(gsg, ctx, percepts)}
  end

  @doc """
  Monty's statistics for one step, written into the buffer.

  `extra` is for a class that composes this one: the numbers only it knows —
  the paths a displacement match came from, say — are merged over what a graph
  module records by itself. Monty gets the same effect by asking the subclass
  from inside `collect_stats_to_save`; a struct that is not this one cannot be
  asked, so it says instead.
  """
  @spec record_stats(t(), map()) :: t()
  def record_stats(%__MODULE__{} = lm, extra \\ %{}) do
    {lm, stats} = collect_stats_to_save(lm)

    %{
      lm
      | buffer:
          FeatureAtLocationBuffer.update_stats(
            lm.buffer,
            Map.merge(stats, extra),
            append: lm.has_detailed_logger
          )
    }
  end
end
