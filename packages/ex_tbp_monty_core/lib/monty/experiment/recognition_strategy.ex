defmodule Monty.Experiment.RecognitionStrategy do
  @moduledoc """
  What counts as "the episode is over".

  Mirrors `tbp/monty/experiment/recognition_strategy.py::RecognitionStrategy`. Each
  learning module decides its own answer; a policy turns those answers, plus the
  step counters, into the one decision the episode loop asks for:
  `%RecognitionResult{is_done: ..., time_out_lms: ..., start_exploring: ...}`.

  ## The model, as a policy sees it

  Monty's policies are handed the model and read a handful of things off it.
  Rather than reach into the runtime's processes, a policy here is given those
  readings as a map — that is what keeps the decision logic pure and comparable
  with Monty's own answers (`scripts/record_monty_recognition_strategy.py`). The
  episode loop is what builds the map, from the model it is holding.

  ## Policies are `{module, state}`

  Each policy is a module plus the numbers it was configured with, which is how
  the rest of this port composes behaviour (`Monty.Experiment.RecognitionStrategy.call/3`),
  and it means `Any` can hold a list of them without knowing what any of them
  are.

  ## What is *not* here

  Monty's policies log and telemeter when they decide (`logger.info`,
  `telemeter.info`). The decision is what is compared; the logging is the
  experiment's business, so it is not on this path.
  """

  alias Monty.Experiment.MatchCriteria.MatchCriterion
  alias Monty.Experiment.RecognitionStrategy.RecognitionContext
  alias Monty.Experiment.RecognitionStrategy.RecognitionResult
  alias Monty.Experiment.RecognitionStatus

  @typedoc """
  The model, as a recognition policy may read it.

  `is_done` is Monty's `model.is_done` — every learning module that matters has
  concluded. `conclusions` is each module's answer, in module order, with `nil`
  for a module that has not concluded. `terminal_states` is the same answers
  keyed by module id, which is the shape a match criterion reads, and
  `match_criterion` is the criterion the model was built with. `processed?` is
  Monty's `check_if_any_lms_updated` for the step just taken: whether a module
  was given something to process, as opposed to only a location to buffer.
  """
  @type model :: %{
          required(:is_done) => boolean(),
          required(:is_exploring) => boolean(),
          required(:matching_steps) => non_neg_integer(),
          required(:processed?) => boolean(),
          required(:min_train_steps) => non_neg_integer(),
          required(:min_eval_steps) => non_neg_integer(),
          required(:num_exploratory_steps) => non_neg_integer(),
          required(:conclusions) => [RecognitionStatus.conclusion() | nil],
          required(:terminal_states) => %{
            optional(atom() | String.t()) => MatchCriterion.terminal_state()
          },
          required(:match_criterion) => {module(), term()}
        }

  @typedoc "A policy and the numbers it was configured with."
  @type t :: {module(), term()}

  @doc """
  Applies a policy to a model and the episode's counters.

  The whole reason a policy is a module and a state: this is the only place that
  need know the shape.
  """
  @spec call(t(), model(), RecognitionContext.t()) :: RecognitionResult.t()
  def call({module, state}, model, counter), do: module.call(model, counter, state)

  @doc """
  The step-type numbers a policy carries, wherever in its chain it holds them.

  Since v0.60.0 Monty keeps `min_train_steps`, `min_eval_steps` and
  `num_exploratory_steps` on a recognition strategy rather than on
  `monty_config`, and a termination group reaches them through `Any` and the
  wrappers. This walks the policy tree for the strategy that carries them; a
  policy that carries none answers `%{}`.

  The model still needs the numbers (`MontyBase.min_steps`), so this is how
  `Monty.Studio.Setup` hands them on: read once, from the policy the config
  names.
  """
  @spec step_type_args(t()) :: map()
  def step_type_args(
        {Monty.Experiment.RecognitionStrategy.MontyForGraphMatchingSetStepTypeAndCheckIfDone, state}
      ),
      do: state

  def step_type_args(
        {Monty.Experiment.RecognitionStrategy.MontyBaseSetStepTypeAndCheckIfDone, state}
      ),
      do: state

  def step_type_args({_module, %{strategies: strategies}}) when is_list(strategies),
    do: Enum.find_value(strategies, %{}, &found_step_type_args/1)

  def step_type_args({_module, %{wrapped: wrapped}}), do: step_type_args(wrapped)

  def step_type_args(_policy_that_carries_none), do: %{}

  # An empty answer is "not here", so the walk goes on to the next member.
  defp found_step_type_args(policy) do
    case step_type_args(policy) do
      args when map_size(args) == 0 -> nil
      args -> args
    end
  end

  @doc """
  The match criterion a policy decides with, wherever in its chain it holds one.

  A criterion written on a strategy (`MatchCriteria`'s, and the graph-matching
  step-type strategy's) is the one the model should carry too, because
  `update_terminal_condition` and the vote round read the model's.
  """
  @spec match_criterion(t()) :: {module(), term()} | nil
  def match_criterion({Monty.Experiment.RecognitionStrategy.MatchCriteria, state}),
    do: Map.get(state, :match_criterion)

  def match_criterion(
        {Monty.Experiment.RecognitionStrategy.MontyForGraphMatchingSetStepTypeAndCheckIfDone, state}
      ),
      do: Map.get(state, :match_criterion)

  def match_criterion({_module, %{strategies: strategies}}) when is_list(strategies),
    do: Enum.find_value(strategies, &match_criterion/1)

  def match_criterion({_module, %{wrapped: wrapped}}), do: match_criterion(wrapped)

  def match_criterion(_policy_that_carries_none), do: nil

  @doc """
  The signature every policy module implements.

  `state` is whatever the policy's `new/1` decided to keep — Monty keeps them as
  instance attributes, which is the same thing without the object.
  """
  @callback call(model(), RecognitionContext.t(), state :: term()) :: RecognitionResult.t()

  # The classes of `experiment/recognition_strategy.py`, by the name a config
  # writes after `tbp.monty.experiment.recognition_strategy.`.
  @policies %{
    "Any" => Monty.Experiment.RecognitionStrategy.Any,
    "MatchCriteria" => Monty.Experiment.RecognitionStrategy.MatchCriteria,
    "MaxTotalSteps" => Monty.Experiment.RecognitionStrategy.MaxTotalSteps,
    "MaximumSteps" => Monty.Experiment.RecognitionStrategy.MaximumSteps,
    "MinEvalMaxTotalSteps" => Monty.Experiment.RecognitionStrategy.MinEvalMaxTotalSteps,
    "MinimumLMs" => Monty.Experiment.RecognitionStrategy.MinimumLMs,
    "MontyBaseSetStepTypeAndCheckIfDone" =>
      Monty.Experiment.RecognitionStrategy.MontyBaseSetStepTypeAndCheckIfDone,
    "MontyForGraphMatchingSetStepTypeAndCheckIfDone" =>
      Monty.Experiment.RecognitionStrategy.MontyForGraphMatchingSetStepTypeAndCheckIfDone,
    "NaiveScan" => Monty.Experiment.RecognitionStrategy.NaiveScan,
    "ObjectRecognition" => Monty.Experiment.RecognitionStrategy.ObjectRecognition,
    "StepLimit" => Monty.Experiment.RecognitionStrategy.StepLimit
  }

  @doc """
  The policy a config names, built.

  Takes Monty's own shape — a map with `_target_` and the policy's arguments —
  and answers `{:ok, {module, state}}` or `{:error, message}`. `wrapped` and
  `strategies` are built first, so a wrapper over a strategy, or an `Any` over
  several, comes out of the same call.

  An option the policy does not have is refused rather than ignored: a config
  written for a policy this port has not caught up with should say so, not run
  a different policy.
  """
  @spec from_config(map()) :: {:ok, t()} | {:error, String.t()}
  def from_config(%{"_target_" => target} = config) do
    with {:ok, module} <- policy_module(target),
         {:ok, options} <- config_options(module, config) do
      module.new(options)
    end
  end

  def from_config(config), do: {:error, "no recognition policy named in #{inspect(config)}"}

  defp policy_module(target) do
    name = target |> String.split(".") |> List.last()

    case Map.fetch(@policies, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "no recognition policy named #{name}"}
    end
  end

  defp config_options(module, config) do
    options = Map.drop(config, ["_target_"])

    with {:ok, nested} <- nested_options(options),
         {:ok, plain} <- plain_options(module, options) do
      {:ok, nested ++ plain}
    end
  end

  # A wrapping or combining policy names its children as strategies of their own,
  # and a step-type policy names the match criterion it decides with.
  defp nested_options(options) do
    with {:ok, wrapped} <- nested(options, "wrapped"),
         {:ok, strategies} <- nested_strategies(options),
         {:ok, criterion} <- nested_criterion(options) do
      {:ok,
       Enum.reject(
         [{:wrapped, wrapped}, {:strategies, strategies}, {:match_criterion, criterion}],
         fn {_key, value} -> is_nil(value) end
       )}
    end
  end

  # Monty's step-type strategy takes a `MatchCriterion` where its siblings take
  # strategies: a config writes `_target_` and the criterion's own arguments.
  defp nested_criterion(options) do
    case Map.fetch(options, "match_criterion") do
      {:ok, config} -> Monty.Experiment.MatchCriteria.from_config(config)
      :error -> {:ok, nil}
    end
  end

  defp nested(options, "wrapped") do
    case Map.fetch(options, "wrapped") do
      {:ok, config} -> from_config(config)
      :error -> {:ok, nil}
    end
  end

  defp nested_strategies(options) do
    case Map.fetch(options, "strategies") do
      {:ok, configs} -> each_strategy(configs)
      :error -> {:ok, nil}
    end
  end

  defp each_strategy(configs) do
    Enum.reduce_while(configs, {:ok, []}, fn config, {:ok, built} ->
      case from_config(config) do
        {:ok, strategy} -> {:cont, {:ok, built ++ [strategy]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # The options each policy takes, which are the keyword names its `new/1`
  # reads. Monty passes them as keyword arguments, so a name a policy does not
  # take is a `TypeError` there and a refusal here — a config written for a
  # policy this port has not caught up with must say so.
  @options %{
    Monty.Experiment.RecognitionStrategy.Any => [:strategies],
    Monty.Experiment.RecognitionStrategy.MatchCriteria => [:match_criterion],
    Monty.Experiment.RecognitionStrategy.MaxTotalSteps => [:max_total_steps],
    Monty.Experiment.RecognitionStrategy.MaximumSteps => [:max_train_steps, :max_eval_steps],
    Monty.Experiment.RecognitionStrategy.MinEvalMaxTotalSteps => [
      :wrapped,
      :min_eval_steps,
      :max_total_steps
    ],
    Monty.Experiment.RecognitionStrategy.MinimumLMs => [:min_lms],
    Monty.Experiment.RecognitionStrategy.MontyBaseSetStepTypeAndCheckIfDone => [
      :min_train_steps,
      :min_eval_steps,
      :num_exploratory_steps
    ],
    Monty.Experiment.RecognitionStrategy.MontyForGraphMatchingSetStepTypeAndCheckIfDone => [
      :match_criterion,
      :min_train_steps,
      :min_eval_steps,
      :num_exploratory_steps
    ],
    Monty.Experiment.RecognitionStrategy.NaiveScan => [:fixed_amount],
    Monty.Experiment.RecognitionStrategy.ObjectRecognition => [
      :max_train_steps,
      :max_eval_steps,
      :max_total_steps
    ],
    Monty.Experiment.RecognitionStrategy.StepLimit => [
      :min_train_steps,
      :num_exploring_steps,
      :max_train_steps,
      :max_eval_steps
    ]
  }

  defp plain_options(module, options) do
    known = Map.fetch!(@options, module)

    options
    |> Map.drop(["wrapped", "strategies", "match_criterion"])
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, built} ->
      atom = String.to_existing_atom(name)

      if atom in known do
        {:cont, {:ok, built ++ [{atom, value}]}}
      else
        {:halt, {:error, "unknown recognition policy option #{name}"}}
      end
    end)
  end
end
