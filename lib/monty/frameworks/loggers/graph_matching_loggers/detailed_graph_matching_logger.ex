defmodule Monty.Frameworks.Loggers.GraphMatchingLoggers.DetailedGraphMatchingLogger do
  @moduledoc """
  `tbp/monty/frameworks/loggers/graph_matching_loggers.py::DetailedGraphMatchingLogger`.

  The basic logger's pool, with the whole episode beside it: every module's buffer
  as it stood at the end of the episode, the motor system's actions and what its
  policy recorded, and a run-wide episode number for each episode so that the
  training and evaluation halves of one run do not collide in a file keyed by it.

  The detail is what makes an episode re-readable. The BASIC stats say a module
  ended up confused; the DETAILED pool has the locations it visited, the features
  it saw there, the displacements between them, and the objects under its sensor
  step by step — which is what a reader needs to say *why*.

  ## Where the modules come from

  Monty reads `model.learning_modules[i].buffer`, because its model is a tree of
  objects. Here a learning module is a process and the coordinator holds only its
  wiring, so the modules are asked for their state at the one moment it is
  wanted — `Monty.Runtime.Model.detailed/1`. That also keeps the cost where Monty
  pays it: once per episode, not once per step.

  ## The episode's number

  Monty's detailed logger keeps `train_episodes_to_total` and
  `eval_episodes_to_total` — maps from the mode's own episode counter to the run's
  — and hands them to its handlers as the `f"{mode}_episodes_to_total"` keyword,
  which is what `DetailedJSONHandler` keys a file by. A studio run is one episode,
  so the maps say `%{0 => 0}`; a run of epochs says `%{0 => 0, 1 => 1, ...}` in
  training and continues counting into evaluation.
  """

  alias Monty.Frameworks.Experiments.Mode.ExperimentMode
  alias Monty.Frameworks.Loggers.GraphMatchingLoggers.BasicGraphMatchingLogger, as: Basic
  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Runtime.Model
  alias Monty.Runtime.Step.State

  defstruct basic: nil, train_episodes_to_total: %{}, eval_episodes_to_total: %{}

  @typedoc """
  A basic logger, and the detail it also keeps.

  `basic` is not a struct field of Monty's — it is inheritance spelled out, since
  Elixir has none: every BASIC question is answered by the logger inside.
  """
  @type t :: %__MODULE__{
          basic: Basic.t(),
          train_episodes_to_total: %{optional(non_neg_integer()) => non_neg_integer()},
          eval_episodes_to_total: %{optional(non_neg_integer()) => non_neg_integer()}
        }

  @doc "A detailed logger that reports through `handlers`."
  @spec new(struct() | [struct()]) :: t()
  def new(handlers \\ []), do: %__MODULE__{basic: Basic.new(handlers)}

  @doc "The pool, for a handler or a test."
  @spec data(t()) :: map()
  def data(%__MODULE__{basic: basic}), do: Basic.data(basic)

  @doc "The handlers this logger reports through."
  @spec handlers(t()) :: [struct()]
  def handlers(%__MODULE__{basic: %Basic{handlers: handlers}}), do: handlers

  @doc """
  `post_episode`: the episode into the pool, then out to the handlers.

  The order is Monty's, and it is the same two steps as the basic logger's: a
  handler is given a pool that has the episode in it, and the flush is what makes
  the next episode's pool empty.
  """
  @spec post_episode(t(), map(), Path.t() | nil, State.t()) :: {:ok, t()} | {:error, term()}
  def post_episode(%__MODULE__{} = logger, logger_args, output_dir, model) do
    {:ok, logger} = update_episode_data(logger, logger_args, model)
    log_episode(logger, logger_args, output_dir, model)
  end

  @doc """
  `log_episode`: the basic fan-out, with this logger's episode numbers.

  Monty overrides this here for one reason: the detailed handlers need
  `episodes_to_total`, and the basic logger has no such counters. It is passed
  under Monty's own keyword so the basic fan-out stays the only one.
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
  `update_episode_data`: the basic pool, then the detailed one beside it.

  The counters are updated before the pool is built, because the pool is keyed by
  the run's episode number rather than by the mode's — an episode is in the file
  under the id the whole run gives it.
  """
  @spec update_episode_data(t(), map(), State.t()) :: {:ok, t()}
  def update_episode_data(%__MODULE__{basic: basic} = logger, logger_args, %State{} = model) do
    {:ok, basic} = Basic.update_episode_data(basic, logger_args, model)
    logger = count_episode(logger, logger_args)

    detailed = detailed_pool(model, logger_args, Basic.mode(logger_args, model))

    data =
      Map.put(
        basic.data,
        "DETAILED",
        Map.put(basic.data["DETAILED"], run_episode(logger, logger_args, model), detailed)
      )

    {:ok, %{logger | basic: %{basic | data: data}}}
  end

  # Monty: `self.train_episodes_to_total[train_episodes] = train + eval`, and the
  # same for evaluation. Both maps are updated on every episode, so a handler can
  # key by either mode's counter.
  defp count_episode(%__MODULE__{} = logger, logger_args) do
    episodes =
      Map.get(logger_args, "train_episodes", 0) + Map.get(logger_args, "eval_episodes", 0)

    %{
      logger
      | train_episodes_to_total:
          Map.put(
            logger.train_episodes_to_total,
            Map.get(logger_args, "train_episodes", 0),
            episodes
          ),
        eval_episodes_to_total:
          Map.put(
            logger.eval_episodes_to_total,
            Map.get(logger_args, "eval_episodes", 0),
            episodes
          )
    }
  end

  defp episodes_to_total(%__MODULE__{train_episodes_to_total: train}, :train), do: train
  defp episodes_to_total(%__MODULE__{eval_episodes_to_total: eval}, :eval), do: eval

  # The run's episode number, as the counter just written says it.
  defp run_episode(%__MODULE__{} = logger, logger_args, %State{} = model) do
    mode = Basic.mode(logger_args, model)

    logger
    |> episodes_to_total(mode)
    |> Map.fetch!(Map.get(logger_args, "#{mode}_episodes", 0))
  end

  @doc """
  The DETAILED pool for a model: its modules as `Monty.Runtime.Model.detailed/1`
  answers them.
  """
  @spec detailed_pool(State.t(), map(), ExperimentMode.t()) :: map()
  def detailed_pool(%State{model_id: model_id}, logger_args, mode) do
    model_id |> Model.detailed() |> pool(logger_args, mode)
  end

  @doc """
  The DETAILED pool: every module as the episode left it.

  Monty's keys, in Monty's order — the episode's own arguments, then the buffer's
  locations and features, its displacements and stats, the mode, and the objects
  under the module's sensor step by step. The later writes win, which is what makes
  a buffer's own stat shadow a logger argument of the same name.
  """
  @spec pool(Monty.Runtime.Step.detailed(), map(), ExperimentMode.t()) :: map()
  def pool(
        %{learning_modules: learning_modules, sensor_modules: sensor_modules, motor: motor},
        logger_args,
        mode
      ) do
    learning_modules
    |> Enum.with_index()
    |> Map.new(fn {spec, index} ->
      {"LM_#{index}", learning_module_pool(spec, logger_args, mode)}
    end)
    |> Map.merge(sensor_module_pool(sensor_modules))
    |> Map.put("motor_system", motor_system_pool(motor))
  end

  defp learning_module_pool(%{state: lm}, logger_args, mode) do
    buffer = lm.buffer

    logger_args
    |> Map.put("locations", buffer.locations)
    |> Map.merge(buffer.features)
    |> Map.put("displacements", buffer.displacements)
    |> Map.merge(buffer.stats)
    |> Map.put("mode", ExperimentMode.to_string(mode))
    |> Map.put("stepwise_targets_list", lm.stepwise_targets_list)
  end

  # Monty writes a sensor module only if it kept raw observations: a sensor with
  # nothing to say about what it saw adds no entry, rather than an empty one.
  defp sensor_module_pool(sensor_modules) do
    sensor_modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {spec, index} ->
      case sensor_module_entry(spec) do
        nil -> []
        entry -> [{"SM_#{index}", entry}]
      end
    end)
    |> Map.new()
  end

  # Monty asks every sensor module for its `state_dict` and keeps it only when it
  # holds raw observations, which is what a run that records what the camera saw
  # has. A module that does not keep one — or keeps a state dict without them —
  # adds no entry rather than an empty one.
  defp sensor_module_entry(%{module: module, state: state}) do
    if function_exported?(module, :state_dict, 1) do
      entry = module.state_dict(state)

      if Enum.empty?(Map.get(entry, "raw_observations", [])), do: nil, else: entry
    end
  end

  # Monty: the actions taken, what the policy's telemetry recorded, and the goals
  # the selector chose. The telemetry is a struct here and `__dict__` there, which
  # is the same map once the struct is opened.
  defp motor_system_pool(nil),
    do: %{"action_sequence" => [], "action_details" => %{}, "policy_selector" => %{}}

  defp motor_system_pool(%MotorSystem{} = motor) do
    %{
      "action_sequence" => MotorSystem.action_sequence(motor),
      "action_details" => motor.telemetry |> Map.from_struct() |> string_keys(),
      "policy_selector" => selector_state(motor.policy_selector)
    }
  end

  # Monty writes `_policy_selector._selected_goals`. The goals are in there, under
  # that name, beside the policy's own record — which `state_dict/1` is for, and is
  # what a reader of a detailed file actually needs to explain an action.
  defp selector_state(selector) do
    selector.__struct__.state_dict(selector) |> string_keys()
  end

  # Monty writes `__dict__`, whose keys are names; a struct's are atoms. Both end
  # up as the same JSON object, and the map a handler is handed says which.
  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
