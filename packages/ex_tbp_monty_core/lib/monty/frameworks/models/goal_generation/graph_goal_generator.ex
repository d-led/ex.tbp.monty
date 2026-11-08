defmodule Monty.Frameworks.Models.GoalGeneration.GraphGoalGenerator do
  @moduledoc """
  Generate sub-goals until the goal it is driving towards is achieved.

  Mirrors `tbp/monty/frameworks/models/goal_generation.py::GraphGoalGenerator`,
  the base goal-state generator (GSG). A GSG belongs to a learning module and
  does one thing on every step: decide whether the goal it last output has been
  achieved, and if so produce the next one. What "achieved" means is the only
  interesting part, and the base class answers it roughly — the sensory input
  changed, so something moved — which is enough for a module that is only
  trying to reduce its own uncertainty.

  This class generates no goals of its own: `generate_goal/2` answers `nil`,
  meaning "carry on, I only want more certainty". `EvidenceGoalGenerator`
  overrides that with the real thing, which is where the work is.

  ## Where the parent module went

  Monty holds a pointer to the learning module and reads it whenever it likes —
  `self.parent_lm.get_output()`. A struct cannot hold a live pointer to a value
  that changes, so a caller hands the generator two things instead: the module
  itself (for its buffer, its step counters and its tolerances) and, through
  `:parent_output`, how to ask it for its current output. The default answers
  `nil`, which is what a module with nothing to say would answer, and Monty's
  only use of that call is comparing against a driving goal that experiments do
  not set yet.
  """

  @behaviour Monty.Frameworks.Models.AbstractMontyClasses.GoalGenerator

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.GoalGeneration.ParentLMNotProvided
  alias Monty.Frameworks.Utils.CommunicationUtils

  # Monty's default: a goal is achieved when nothing changed by more than this.
  @default_goal_tolerances %{"location" => 0.015}

  # Logged against the parent module's buffer so a run can be read afterwards:
  # what each goal was, when it was set, and whether it was achieved.
  @goal_stat_keys ["goal_states", "matching_step_when_output_goal_set", "goal_state_achieved"]

  defstruct parent_lm: nil,
            parent_output: nil,
            goal_tolerances: @default_goal_tolerances,
            keep_output_goal: nil,
            driving_goal: nil,
            output_goal: nil

  @type t :: %__MODULE__{
          parent_lm: map() | nil,
          parent_output: (-> term()) | nil,
          goal_tolerances: map(),
          keep_output_goal: (-> boolean()) | nil,
          driving_goal: Goal.t() | nil,
          output_goal: Goal.t() | nil
        }

  @doc """
  A generator with no goals yet.

  `:goal_tolerances` says how close is close enough per goal attribute — a
  distance in metres for `"location"` unless an experiment says otherwise; it is
  the GSG's own tolerance, not the learning module's matching tolerance, because
  the question here is whether a goal was reached, not whether two things look
  alike. `:parent_output` is how to ask the parent module for its output.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      goal_tolerances: Keyword.get(options, :goal_tolerances) || @default_goal_tolerances,
      parent_output: Keyword.get(options, :parent_output, fn -> nil end),
      keep_output_goal: Keyword.get(options, :keep_output_goal, fn -> true end)
    }
  end

  @doc """
  The generator a config entry describes.

  On its own it emits no goal, which is what an experiment that only wants a
  learning module to keep matching asks for.
  """
  @spec from_config(map()) :: t()
  def from_config(config), do: new(goal_tolerances: Map.get(config, "goal_tolerances"))

  @doc """
  The learning module this generator reads, or an error when there is none.
  """
  @impl true
  @spec parent_lm(t()) :: map()
  def parent_lm(%__MODULE__{parent_lm: nil}) do
    raise ParentLMNotProvided
  end

  def parent_lm(%__MODULE__{parent_lm: lm}), do: lm

  @doc """
  Points this generator at its learning module and resets it.

  Setting the module resets, because goals left over from another module belong
  to another object.
  """
  @impl true
  @spec put_parent_lm(t(), map()) :: t()
  def put_parent_lm(%__MODULE__{} = generator, parent_lm) do
    reset(%{generator | parent_lm: parent_lm})
  end

  @doc """
  The same generator, now reading `parent_lm` as it stands.

  Monty holds a pointer to its module and so sees every change to it for free.
  A struct holds a copy, so whatever drives the generator hands it the module
  again before each step — without resetting, because the schedule the
  generator has built up still belongs to this module.
  """
  @spec point_at(t(), map()) :: t()
  def point_at(%__MODULE__{} = generator, parent_lm), do: %{generator | parent_lm: parent_lm}

  @doc """
  Receives the high-level goal to drive towards.

  Monty's experiments never set one yet, so this stays `nil`: the default goal
  is "be more certain", which the base class cannot check and therefore never
  achieves — a module keeps gathering evidence for as long as the experiment
  lets it.
  """
  @impl true
  @spec set_driving_goal(t(), Goal.t() | nil) :: t()
  def set_driving_goal(%__MODULE__{} = generator, goal),
    do: %{generator | driving_goal: goal}

  @doc "The goal this generator wants others to achieve, or none."
  @impl true
  @spec output_goals(t()) :: [Goal.t()]
  def output_goals(%__MODULE__{output_goal: nil}), do: []
  def output_goals(%__MODULE__{output_goal: goal}), do: [goal]

  @doc """
  Forgets the goals held so far and starts the log over.

  The log lives on the parent module's buffer, which is why this needs one.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = generator) do
    generator = %{generator | driving_goal: nil, output_goal: nil}

    case generator.parent_lm do
      parent_lm when is_map(parent_lm) ->
        log_goals(generator, parent_lm, %{}, append: false, init_list: false)

      _no_parent_lm ->
        generator
    end
  end

  @doc """
  One step: was the last goal achieved, and if so what is next.

  Running out of goals is not an error — the module carries on with no goal,
  which for the base class is the whole of its behaviour.
  """
  @impl true
  @spec step(t(), Monty.Context.t(), [Message.t()]) :: t()
  def step(%__MODULE__{} = generator, _ctx, observations) do
    achieved? = output_goal_achieved?(generator, observations)
    generator = log_goal_state(generator, achieved?)

    cond do
      need_new_output_goal?(achieved?) ->
        %{generator | output_goal: generate_goal(generator, observations)}

      keep_current_output_goal?(generator) ->
        generator

      true ->
        %{generator | output_goal: nil}
    end
  end

  # -- what a goal is worth ------------------------------------------------

  @doc """
  Whether the last output goal was achieved, judged from the sensory input.

  The prediction is only "the input changed": a motor system that fails to
  reach its goal usually moves back, so a step that shows the same thing twice
  is a step where the agent went nowhere. That is approximate on purpose — the
  alternative needs a predicted percept, which needs a model of the world from a
  goal's point of view, and Monty's own comment says so.
  """
  @spec output_goal_achieved?(t(), [Message.t()]) :: boolean()
  def output_goal_achieved?(%__MODULE__{output_goal: nil}, _observations), do: false

  def output_goal_achieved?(%__MODULE__{} = generator, observations) do
    buffer = buffer(generator)

    with {:ok, channel} <- FeatureAtLocationBuffer.get_first_sensory_input_channel(buffer),
         {:ok, current} <- CommunicationUtils.get_percept_from_channel(observations, channel),
         previous when not is_nil(previous) <- previous_percept_on(buffer, channel) do
      messages_different?(current, previous, generator.goal_tolerances)
    else
      # No channel, no history, or the same channel was not in it: nothing can
      # be said about whether the goal was reached, and guessing "yes" would
      # move the agent on without evidence.
      _ -> false
    end
  end

  # Monty keeps one list of percepts per step and picks the channel out of the
  # previous step's list. Our buffer keeps percepts flat, so the previous
  # percept is only the one to compare against when it came over the same
  # channel — which for one sensor per step is the same thing.
  defp previous_percept_on(buffer, channel) do
    case FeatureAtLocationBuffer.get_previous_input_percepts(buffer) do
      %Message{sender_id: ^channel} = previous -> previous
      _another_channel_or_none -> nil
    end
  end

  @doc """
  Whether two messages differ by more than the given tolerances.

  One feature outside its tolerance is enough. An undefined message, or an
  attribute both messages leave undefined, says nothing and is not a
  difference — which is what makes a goal with only a location meaningful.
  """
  @spec messages_different?(Message.t() | nil, Message.t() | nil, map()) :: boolean()
  def messages_different?(nil, _message, _tolerances), do: false
  def messages_different?(_message, nil, _tolerances), do: false

  def messages_different?(%Message{} = message_a, %Message{} = message_b, tolerances) do
    Enum.any?(tolerances, fn {key, tolerance} ->
      case distance(message_a, message_b, key) do
        nil -> false
        value -> value > tolerance
      end
    end)
  end

  defp distance(message_a, message_b, "location") do
    case {message_a.location, message_b.location} do
      {nil, _} ->
        nil

      {_, nil} ->
        nil

      {location_a, location_b} ->
        Monty.Frameworks.Utils.SpatialArithmetics.magnitude(
          Monty.Frameworks.Utils.SpatialArithmetics.subtract(location_a, location_b)
        )
    end
  end

  defp distance(_message_a, _message_b, "pose_vectors") do
    raise ArgumentError,
          "comparing poses is not implemented: a pose comparison has to handle an object's " <>
            "symmetries, and Monty raises the same"
  end

  defp distance(_message_a, _message_b, _other), do: nil

  # -- generating ----------------------------------------------------------

  # The base class generates nothing: a `nil` goal means "I only want to be
  # more certain", which is what an experiment's default driving goal asks for.
  defp generate_goal(_generator, _observations), do: nil

  defp need_new_output_goal?(achieved?), do: achieved?

  # Whether to keep the goal in hand when it was not achieved. Always yes here;
  # a subclass that would rather drop it says so with its own `:keep_output_goal`.
  defp keep_current_output_goal?(%__MODULE__{keep_output_goal: keep?}), do: keep?.()

  @doc """
  The buffer this generator reads from and records into.

  Goals are logged on the parent module's buffer rather than on the generator,
  so that everything a step learned about a module is read from one place
  afterwards.
  """
  @spec buffer(t()) :: FeatureAtLocationBuffer.t()
  def buffer(%__MODULE__{} = generator) do
    generator |> parent_lm() |> Map.fetch!(:buffer)
  end

  # -- logging -------------------------------------------------------------

  @doc """
  Records whether the goal in hand was achieved on this step.

  The goal was set — and could have been achieved — on the previous step, which
  is why the recorded matching step is the one before this.
  """
  @spec log_goal_state(t(), boolean()) :: t()
  def log_goal_state(%__MODULE__{output_goal: nil} = generator, _achieved?), do: generator

  def log_goal_state(%__MODULE__{} = generator, achieved?) do
    # The goal was set — and could have been achieved — on the previous step,
    # which is why the matching step is the one before this.
    match_step = FeatureAtLocationBuffer.get_num_matching_steps(buffer(generator)) - 1

    goal = %{
      generator.output_goal
      | info:
          Map.merge(generator.output_goal.info, %{
            "achieved" => achieved?,
            "matching_step_when_output_goal_set" => match_step
          })
    }

    log_goals(
      %{generator | output_goal: goal},
      parent_lm(generator),
      %{
        "goal_states" => goal,
        "matching_step_when_output_goal_set" => match_step,
        "goal_state_achieved" => achieved?
      },
      append: true,
      init_list: true
    )
  end

  defp log_goals(%__MODULE__{} = generator, parent_lm, stats, opts) do
    buffer =
      parent_lm
      |> Map.fetch!(:buffer)
      |> FeatureAtLocationBuffer.update_stats(stats,
        update_time: false,
        append: Keyword.fetch!(opts, :append),
        init_list: Keyword.fetch!(opts, :init_list)
      )

    %{generator | parent_lm: Map.put(parent_lm, :buffer, buffer)}
  end

  @doc "The statistics this generator keeps on its parent's buffer."
  @spec goal_stat_keys() :: [String.t()]
  def goal_stat_keys, do: @goal_stat_keys
end
