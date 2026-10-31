defmodule Monty.Frameworks.Loggers.GraphMatchingLoggers.SelectiveEvidenceLogger do
  @moduledoc """
  `tbp/monty/frameworks/loggers/graph_matching_loggers.py::SelectiveEvidenceLogger`.

  The slimmed-down detailed logger: the evidence each hypothesis carried, and
  where it thought each object could be, at the end of an episode — the data an
  object-similarity analysis is made of, without the buffers that make a detailed
  file large.

  What it writes for each learning module, and why each one is kept as Monty keeps
  it:

    * `evidences_ls` and `possible_locations_ls` — the last step's only, because
      that is the state the episode ended in;
    * `possible_rotations_ls` — the whole statistic, because possible poses do not
      change over an episode and are written once;
    * `possible_matches`, `current_mlh` and `symmetry_evidence` — every step, so a
      reader can see how the belief moved rather than only where it landed.

  A sensor module contributes the first raw observation it kept, and nothing if it
  kept none — the first frame of the view finder, which is what a similarity
  analysis compares against later episodes.

  ## The bookkeeping it shares, and does not

  Monty's class is a sibling of `DetailedGraphMatchingLogger`, not its child: both
  add up an episode number for the whole run beside the mode's own counter, and
  Monty writes those three methods out in both classes. So does this, and the
  repetition is Monty's rather than an accident — Elixir has no inheritance to put
  them in one place, and an invented base class would be a module its own map does
  not know.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode
  alias Monty.Frameworks.Loggers.GraphMatchingLoggers.BasicGraphMatchingLogger, as: Basic
  alias Monty.Runtime.Model
  alias Monty.Runtime.Step.State

  defstruct basic: nil, train_episodes_to_total: %{}, eval_episodes_to_total: %{}

  @typedoc "A basic logger, and the run-wide episode numbers beside its pools."
  @type t :: %__MODULE__{
          basic: Basic.t(),
          train_episodes_to_total: %{optional(non_neg_integer()) => non_neg_integer()},
          eval_episodes_to_total: %{optional(non_neg_integer()) => non_neg_integer()}
        }

  @doc "A selective evidence logger that reports through `handlers`."
  @spec new(struct() | [struct()]) :: t()
  def new(handlers \\ []), do: %__MODULE__{basic: Basic.new(handlers)}

  @doc "The pool, for a handler or a test."
  @spec data(t()) :: map()
  def data(%__MODULE__{basic: basic}), do: Basic.data(basic)

  @doc "The handlers this logger reports through."
  @spec handlers(t()) :: [struct()]
  def handlers(%__MODULE__{basic: %Basic{handlers: handlers}}), do: handlers

  @doc "`post_episode`: the episode into the pool, then out to the handlers."
  @spec post_episode(t(), map(), Path.t() | nil, State.t()) :: {:ok, t()} | {:error, term()}
  def post_episode(%__MODULE__{} = logger, logger_args, output_dir, model) do
    {:ok, logger} = update_episode_data(logger, logger_args, model)
    log_episode(logger, logger_args, output_dir, model)
  end

  @doc """
  `log_episode`: the basic fan-out, with this logger's episode numbers.

  Its handlers key a file by the run's episode id, so the numbers go under Monty's
  own keyword and the basic fan-out stays the only one.
  """
  @spec log_episode(t(), map(), Path.t() | nil, State.t()) :: {:ok, t()} | {:error, term()}
  def log_episode(%__MODULE__{basic: basic} = logger, logger_args, output_dir, model) do
    mode = Basic.mode(logger_args, model)

    args =
      Map.put(logger_args, "#{mode}_episodes_to_total", episodes_to_total(logger, mode))

    case Basic.log_episode(basic, args, output_dir, model) do
      {:ok, basic} -> {:ok, %{logger | basic: basic}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `update_episode_data`: the basic pool, then the evidence pool beside it.

  The counters move first, because the pool is keyed by the run's episode number
  rather than by the mode's.
  """
  @spec update_episode_data(t(), map(), State.t()) :: {:ok, t()}
  def update_episode_data(%__MODULE__{basic: basic} = logger, logger_args, %State{} = model) do
    {:ok, basic} = Basic.update_episode_data(basic, logger_args, model)
    logger = count_episode(logger, logger_args)

    evidence = evidence_pool(model, logger_args, Basic.mode(logger_args, model))

    data =
      Map.put(
        basic.data,
        "DETAILED",
        Map.put(basic.data["DETAILED"], run_episode(logger, logger_args, model), evidence)
      )

    {:ok, %{logger | basic: %{basic | data: data}}}
  end

  # Monty: `self.train_episodes_to_total[train_episodes] = train + eval`, and the
  # same for evaluation, on every episode.
  defp count_episode(%__MODULE__{} = logger, logger_args) do
    train = Map.get(logger_args, "train_episodes", 0)
    eval = Map.get(logger_args, "eval_episodes", 0)

    %{
      logger
      | train_episodes_to_total: Map.put(logger.train_episodes_to_total, train, train + eval),
        eval_episodes_to_total: Map.put(logger.eval_episodes_to_total, eval, train + eval)
    }
  end

  defp episodes_to_total(%__MODULE__{train_episodes_to_total: train}, :train), do: train
  defp episodes_to_total(%__MODULE__{eval_episodes_to_total: eval}, :eval), do: eval

  defp run_episode(%__MODULE__{} = logger, logger_args, %State{} = model) do
    mode = Basic.mode(logger_args, model)

    logger
    |> episodes_to_total(mode)
    |> Map.fetch!(Map.get(logger_args, "#{mode}_episodes", 0))
  end

  @doc """
  The evidence pool for a model: its modules as `Monty.Runtime.Model.detailed/1`
  answers them.
  """
  @spec evidence_pool(State.t(), map(), ExperimentMode.t()) :: map()
  def evidence_pool(%State{model_id: model_id}, logger_args, mode) do
    model_id |> Model.detailed() |> pool(logger_args, mode)
  end

  @doc """
  The pool, from the modules as they are.

  `logger_args` and `mode` are taken and do not appear in what comes out: Monty's
  signature carries them and this is the same call, so a reader comparing the two
  finds the same arguments rather than one that has been trimmed to what this class
  happens to use.
  """
  @spec pool(Monty.Runtime.Step.detailed(), map(), ExperimentMode.t()) :: map()
  def pool(
        %{learning_modules: learning_modules, sensor_modules: sensor_modules},
        _logger_args,
        _mode
      ) do
    learning_modules
    |> Enum.with_index()
    |> Map.new(fn {spec, index} -> {"LM_#{index}", learning_module_evidence(spec.state)} end)
    |> Map.merge(sensor_module_frames(sensor_modules))
  end

  # Monty's `[-1]` is "the step the episode ended on"; an episode that never
  # stepped has no such step, and `nil` says that where an `IndexError` would say
  # it in Python.
  defp learning_module_evidence(%{buffer: buffer}) do
    %{
      "evidences_ls" => last(buffer.stats, "evidences"),
      "possible_locations_ls" => last(buffer.stats, "possible_locations"),
      "possible_rotations_ls" => Map.get(buffer.stats, "possible_rotations"),
      "possible_matches" => Map.get(buffer.stats, "possible_matches"),
      "current_mlh" => Map.get(buffer.stats, "current_mlh"),
      "symmetry_evidence" => Map.get(buffer.stats, "symmetry_evidence")
    }
  end

  defp last(stats, key), do: stats |> Map.get(key, []) |> List.wrap() |> List.last()

  # The first frame a sensor kept, which is what a similarity analysis compares
  # against; a sensor that kept none contributes nothing.
  defp sensor_module_frames(sensor_modules) do
    sensor_modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {spec, index} ->
      case first_observation(spec) do
        nil -> []
        frame -> [{"SM_#{index}", frame}]
      end
    end)
    |> Map.new()
  end

  defp first_observation(%{module: module, state: state}) do
    if function_exported?(module, :state_dict, 1) do
      module.state_dict(state) |> Map.get("raw_observations", []) |> List.first()
    end
  end
end
