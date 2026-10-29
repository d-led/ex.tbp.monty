defmodule Monty.Experiment.RecognitionPolicy do
  @moduledoc """
  What counts as "the episode is over".

  Mirrors `tbp/monty/experiment/recognition_policy.py::RecognitionPolicy`. Each
  learning module decides its own answer; a policy turns those answers, plus the
  step counters, into the one decision the episode loop asks for:
  `%RecognitionResult{is_done: ..., time_out_lms: ..., start_exploring: ...}`.

  ## The model, as a policy sees it

  Monty's policies are handed the model and read four things off it. Rather than
  reach into the runtime's processes, a policy here is given those four things as
  a map — that is what keeps the decision logic pure and comparable with Monty's
  own answers (`scripts/record_monty_recognition_policy.py`). The episode loop is
  what builds the map, from the model it is holding.

  ## Policies are `{module, state}`

  Each policy is a module plus the numbers it was configured with, which is how
  the rest of this port composes behaviour (`Monty.Experiment.RecognitionPolicy.call/3`),
  and it means `AnyPolicy` can hold a list of them without knowing what any of
  them are.

  ## What is *not* here

  Monty's policies log and telemeter when they decide (`logger.info`,
  `telemeter.info`). The decision is what is compared; the logging is the
  experiment's business, so it is not on this path.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionCounter
  alias Monty.Experiment.RecognitionPolicy.RecognitionResult
  alias Monty.Experiment.RecognitionStatus

  @typedoc """
  The model, as a recognition policy may read it.

  `is_done` is Monty's `model.is_done` — every learning module that matters has
  concluded. `conclusions` is each module's answer, in module order, with `nil`
  for a module that has not concluded.
  """
  @type model :: %{
          required(:is_done) => boolean(),
          required(:is_exploring) => boolean(),
          required(:matching_steps) => non_neg_integer(),
          required(:conclusions) => [RecognitionStatus.conclusion() | nil]
        }

  @typedoc "A policy and the numbers it was configured with."
  @type t :: {module(), term()}

  @doc """
  Applies a policy to a model and the episode's counters.

  The whole reason a policy is a module and a state: this is the only place that
  need know the shape.
  """
  @spec call(t(), model(), RecognitionCounter.t()) :: RecognitionResult.t()
  def call({module, state}, model, counter), do: module.call(model, counter, state)

  @doc """
  The signature every policy module implements.

  `state` is whatever the policy's `new/1` decided to keep — Monty keeps them as
  instance attributes, which is the same thing without the object.
  """
  @callback call(model(), RecognitionCounter.t(), state :: term()) :: RecognitionResult.t()

  # The classes of `experiment/recognition_policy.py`, by the name a config
  # writes after `tbp.monty.experiment.recognition_policy.`.
  @policies %{
    "AnyPolicy" => Monty.Experiment.RecognitionPolicy.AnyPolicy,
    "MaxTotalSteps" => Monty.Experiment.RecognitionPolicy.MaxTotalSteps,
    "MaximumSteps" => Monty.Experiment.RecognitionPolicy.MaximumSteps,
    "MinEvalMaxTotalSteps" => Monty.Experiment.RecognitionPolicy.MinEvalMaxTotalSteps,
    "MinimumLMs" => Monty.Experiment.RecognitionPolicy.MinimumLMs,
    "MontyIsDone" => Monty.Experiment.RecognitionPolicy.MontyIsDone,
    "NaiveScan" => Monty.Experiment.RecognitionPolicy.NaiveScan,
    "ObjectRecognition" => Monty.Experiment.RecognitionPolicy.ObjectRecognition,
    "StepLimit" => Monty.Experiment.RecognitionPolicy.StepLimit
  }

  @doc """
  The policy a config names, built.

  Takes Monty's own shape — a map with `_target_` and the policy's arguments —
  and answers `{:ok, {module, state}}` or `{:error, message}`. `wrapped` and
  `policies` are built first, so a wrapper over a policy, or an `AnyPolicy` over
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

  # A wrapping or combining policy names its children as policies of their own.
  defp nested_options(options) do
    with {:ok, wrapped} <- nested(options, "wrapped"),
         {:ok, policies} <- nested_policies(options) do
      {:ok,
       Enum.reject([{:wrapped, wrapped}, {:policies, policies}], fn {_key, value} ->
         is_nil(value)
       end)}
    end
  end

  defp nested(options, "wrapped") do
    case Map.fetch(options, "wrapped") do
      {:ok, config} -> from_config(config)
      :error -> {:ok, nil}
    end
  end

  defp nested_policies(options) do
    case Map.fetch(options, "policies") do
      {:ok, configs} -> each_policy(configs)
      :error -> {:ok, nil}
    end
  end

  defp each_policy(configs) do
    Enum.reduce_while(configs, {:ok, []}, fn config, {:ok, built} ->
      case from_config(config) do
        {:ok, policy} -> {:cont, {:ok, built ++ [policy]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # The options each policy takes, which are the keyword names its `new/1`
  # reads. Monty passes them as keyword arguments, so a name a policy does not
  # take is a `TypeError` there and a refusal here — a config written for a
  # policy this port has not caught up with must say so.
  @options %{
    Monty.Experiment.RecognitionPolicy.AnyPolicy => [:policies],
    Monty.Experiment.RecognitionPolicy.MaxTotalSteps => [:max_total_steps],
    Monty.Experiment.RecognitionPolicy.MaximumSteps => [:max_train_steps, :max_eval_steps],
    Monty.Experiment.RecognitionPolicy.MinEvalMaxTotalSteps => [
      :wrapped,
      :min_eval_steps,
      :max_total_steps
    ],
    Monty.Experiment.RecognitionPolicy.MinimumLMs => [:min_lms],
    Monty.Experiment.RecognitionPolicy.MontyIsDone => [],
    Monty.Experiment.RecognitionPolicy.NaiveScan => [:fixed_amount],
    Monty.Experiment.RecognitionPolicy.ObjectRecognition => [
      :max_train_steps,
      :max_eval_steps,
      :max_total_steps
    ],
    Monty.Experiment.RecognitionPolicy.StepLimit => [
      :min_train_steps,
      :num_exploring_steps,
      :max_train_steps,
      :max_eval_steps
    ]
  }

  defp plain_options(module, options) do
    known = Map.fetch!(@options, module)

    options
    |> Map.drop(["wrapped", "policies"])
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
