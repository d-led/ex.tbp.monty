defmodule Monty.Frameworks.Loggers.GraphMatchingLoggers.BasicGraphMatchingLogger do
  @moduledoc """
  `tbp/monty/frameworks/loggers/graph_matching_loggers.py::BasicGraphMatchingLogger`.

  The pool of data an episode fills, and the handler fan-out that empties it.

  Monty's description of its own loggers is worth keeping: the logger builds a pool
  (`self.data`), the handlers take subsets of it and send them somewhere — a CSV, a
  JSON file, wandb. The pool is written at `post_episode`, reported to every
  handler at the same point, and flushed afterwards so the next episode starts
  empty.

  The pool's shape is Monty's, because the handlers read it:

      %{"BASIC" => %{"train_stats" => %{episode => %{"LM_0" => stats}}, ...},
        "DETAILED" => %{}}

  ## The model a logger is given

  Monty hands its loggers a `model` with `experiment_mode`, `episode_steps`,
  `matching_steps`, its learning modules and its motor system's action sequence.
  Here that is `Monty.Runtime.Step.State`: the coordinator already carries the mode,
  both step counts, the modules and the motor state, so a logger asked for "the
  model" is handed the one value that has all of it.

  ## What is not ported yet

  `wandb.Histogram` values are not built here. They are wandb's own type, they only
  exist when a run has more than one learning module, and the distributions they
  carry are the lists this module already keeps — so they belong with the wandb
  handlers rather than in the pool. Everything numeric and every per-LM figure is
  computed exactly as Monty computes it.

  A mean Monty writes as `np.nan` is `nil` here: both come out as an empty CSV
  cell, and a `nil` says "nothing was measured" without needing a float that
  behaves like a value.
  """

  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Frameworks.Utils.LoggingUtils
  alias Monty.Runtime.Step.State

  # Monty's `performance_options`, in its order: the order matters because the
  # last match wins when an episode's modules disagree.
  @performance_options [
    "patch_off_object",
    "no_label",
    "pose_time_out",
    "time_out",
    "confused_mlh",
    "correct_mlh",
    "no_match",
    "confused",
    "correct"
  ]

  @modes [:train, :eval]

  defstruct handlers: [], data: nil, overall_train_stats: nil, overall_eval_stats: nil, lms: []

  @typedoc "The pool of data one episode fills, and the run's counters beside it."
  @type t :: %__MODULE__{
          handlers: [struct()],
          data: map(),
          overall_train_stats: map(),
          overall_eval_stats: map(),
          lms: [String.t()]
        }

  @doc "A logger that reports through `handlers`."
  @spec new(struct() | [struct()]) :: t()
  def new(handlers \\ []) do
    overall = initial_overall_stats()

    %__MODULE__{
      handlers: List.wrap(handlers),
      data: empty_data(),
      overall_train_stats: overall,
      overall_eval_stats: overall,
      lms: []
    }
  end

  @doc "The pool, for a handler or a test."
  @spec data(t()) :: map()
  def data(%__MODULE__{data: data}), do: data

  @doc "Monty's `flush`: an empty pool for the next episode."
  @spec flush(t()) :: t()
  def flush(%__MODULE__{} = logger), do: %{logger | data: empty_data()}

  @doc """
  `post_episode`: write the episode into the pool, report it, and flush.

  Monty's order, and its reason: a handler is given the pool the episode just
  filled, and `log_episode` is what flushes it — a logger that flushed first would
  hand every handler an empty pool.
  """
  @spec post_episode(t(), map(), Path.t() | nil, State.t()) :: {:ok, t()} | {:error, term()}
  def post_episode(%__MODULE__{} = logger, logger_args, output_dir, model) do
    {:ok, logger} = update_episode_data(logger, logger_args, model)
    log_episode(logger, logger_args, output_dir, model)
  end

  @doc """
  `log_episode`: hand the pool to every handler, then start a new one.

  A handler that fails stops the fan-out, which is the same rule the callback
  handler follows: a run whose statistics were half written is not one whose
  statistics can be trusted.
  """
  @spec log_episode(t(), map(), Path.t() | nil, State.t()) ::
          {:ok, t()} | {:error, term()}
  def log_episode(%__MODULE__{} = logger, logger_args, output_dir, model) do
    mode = mode(logger_args, model)
    episode = episode(logger_args, mode)

    logger.handlers
    |> Enum.reduce_while({:ok, logger}, fn handler, {:ok, logger} ->
      case handler.__struct__.report_episode(
             handler,
             logger.data,
             output_dir,
             episode,
             mode,
             episodes_to_total(logger_args, mode)
           ) do
        {:ok, updated} -> {:cont, {:ok, replace_handler(logger, handler, updated)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, logger} -> {:ok, flush(logger)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `update_episode_data`: what the episode did, into the pool and the counters.

  The performance dictionary is the one the CSV rows are built from — keyed `LM_0`,
  `LM_1` by position — and the target is written beside it, because a row that
  cannot say which object the episode was about cannot be compared with one that
  can.
  """
  @spec update_episode_data(t(), map(), State.t()) :: {:ok, t()}
  def update_episode_data(%__MODULE__{} = logger, logger_args, model) do
    mode = mode(logger_args, model)
    episode = episode(logger_args, mode)
    target = Map.get(logger_args, "target")
    modules = learning_modules(model)

    performance =
      LoggingUtils.stats_per_lm(modules, target,
        step: steps(model),
        matching_steps: matching_steps(model),
        episode_seed: Map.get(logger_args, "episode_seed")
      )

    logger = %{logger | lms: if(logger.lms == [], do: Map.keys(performance), else: logger.lms)}

    stats =
      performance
      |> Map.put("target", LoggingUtils.target_data_to_dict(target || %{}))

    logger =
      put_basic(logger, mode, "stats", Map.put(basic(logger, mode, "stats"), episode, stats))

    logger = update_overall_stats(logger, mode, episode, steps(model), matching_steps(model))
    overall = formatted_overall_stats(logger, mode, episode)

    {
      :ok,
      logger
      |> put_basic(
        mode,
        "overall_stats",
        Map.put(basic(logger, mode, "overall_stats"), episode, overall)
      )
      |> put_basic(
        mode,
        "actions",
        Map.put(basic(logger, mode, "actions"), episode, actions(model))
      )
      |> put_basic(
        mode,
        "targets",
        Map.put(basic(logger, mode, "targets"), episode, stats["target"])
      )
      |> put_basic(
        mode,
        "timing",
        Map.put(basic(logger, mode, "timing"), episode, timing(logger_args))
      )
    }
  end

  @doc """
  `update_overall_stats`: the run's counters, moved on by one episode.

  Two things happen here that are worth naming. A module's performance is counted
  per module *and* folded into the episode's: the episode is `correct` if any
  module was correct, because that is what the model concluded — which is why the
  options are checked in order and the strongest last.
  """
  @spec update_overall_stats(t(), atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          t()
  def update_overall_stats(%__MODULE__{} = logger, mode, episode, steps, matching_steps) do
    per_module = basic(logger, mode, "stats") |> Map.get(episode, %{})

    {stats, performances} =
      count_modules(overall_stats(logger, mode), logger.lms, per_module, steps, matching_steps)

    stats = %{
      stats
      | "episode_lm_performances" => stats["episode_lm_performances"] ++ [performances]
    }

    stats = count_episode(stats, performances, episode_performance(performances))

    put_overall_stats(logger, mode, %{stats | "num_episodes" => stats["num_episodes"] + 1})
  end

  defp count_modules(stats, lms, per_module, steps, matching_steps) do
    Enum.reduce(lms, {stats, []}, fn lm, {stats, performances} ->
      module = Map.get(per_module, lm, %{})
      performance = module["primary_performance"]
      stats = count_per_module(stats, module, performance, steps, matching_steps)

      performances =
        if performance == nil, do: performances, else: performances ++ [performance]

      {stats, performances}
    end)
  end

  defp count_per_module(stats, module, performance, steps, matching_steps) do
    stats =
      stats
      |> update_and_append("rotation_errors", module["rotation_error"])
      |> update_and_append("run_times", module["time"])
      |> update_and_append("episode_lm_steps", module["num_steps"])
      |> update_and_append("episode_lm_steps_indv_ts", module["individual_ts_reached_at_step"])
      |> update_and_append("episode_symmetry_evidence", module["symmetry_evidence"])
      |> update_and_append("monty_steps", steps)
      |> update_and_append("monty_matching_steps", matching_steps)
      |> update_and_append(
        "episode_avg_prediction_error",
        Map.get(module, "episode_avg_prediction_error")
      )

    stats
    |> Map.put("goal_states_attempted", module["goal_states_attempted"] || 0)
    |> Map.put("goal_state_success_rate", success_rate(module))
    |> count_performance(performance)
  end

  # Monty counts a module's performance beside the episode's, and a module that
  # reported none (a pretraining run) is not counted at all.
  defp count_performance(stats, nil), do: stats

  defp count_performance(stats, performance) do
    Map.update(stats, "num_#{performance}_per_lm", 1, &(&1 + 1))
  end

  defp success_rate(module) do
    case module["goal_states_attempted"] do
      attempted when is_integer(attempted) and attempted > 0 ->
        (module["goal_state_achieved"] || 0) / attempted

      _none ->
        0
    end
  end

  # `episode_performance` is only `no_match` when no module had anything stronger,
  # which is why the options are walked in order and every match overwrites.
  defp episode_performance(performances) do
    Enum.reduce(@performance_options, nil, fn option, current ->
      if option in performances, do: option, else: current
    end)
  end

  defp count_episode(stats, _performances, nil), do: stats

  defp count_episode(stats, _performances, performance) do
    Enum.reduce(@performance_options, stats, fn option, stats ->
      counted = if option == performance, do: 1, else: 0

      stats
      |> Map.put("episode_#{option}", counted)
      |> Map.put("num_#{option}", Map.get(stats, "num_#{option}", 0) + counted)
    end)
  end

  @doc """
  `get_formatted_overall_stats`: the run's figures as wandb and a reader see them.

  Monty's keys, its arithmetic and its rounding: a percentage where it is a
  percentage, a mean where it is a mean, and `nil` where it takes a mean of
  nothing — which its readers see as a blank cell rather than as zero.
  """
  @spec formatted_overall_stats(t(), atom(), non_neg_integer()) :: map()
  def formatted_overall_stats(%__MODULE__{} = logger, mode, episode) do
    stats = overall_stats(logger, mode)
    episodes = stats["num_episodes"]
    modules = length(logger.lms)

    rotation_errors = Enum.reject(stats["rotation_errors"], &is_nil/1)

    episode_errors = stats["rotation_errors"] |> last_for(modules) |> Enum.reject(&is_nil/1)

    individual_ts_steps =
      stats["episode_lm_steps_indv_ts"] |> last_for(modules) |> Enum.reject(&is_nil/1)

    overall = %{
      "overall/percent_correct" =>
        percent(stats["num_correct"] + stats["num_correct_mlh"], episodes),
      "overall/percent_no_match" => percent(stats["num_no_match"], episodes),
      "overall/percent_confused" =>
        percent(stats["num_confused"] + stats["num_confused_mlh"], episodes),
      "overall/percent_correct_mlh" => percent(stats["num_correct_mlh"], episodes),
      "overall/percent_confused_mlh" => percent(stats["num_confused_mlh"], episodes),
      "overall/percent_pose_time_out" => percent(stats["num_pose_time_out"], episodes),
      "overall/percent_time_out" => percent(stats["num_time_out"], episodes),
      "overall/percent_used_mlh_after_timeout" =>
        percent(stats["num_correct_mlh"] + stats["num_confused_mlh"], episodes),
      "overall/avg_rotation_error" => mean(rotation_errors),
      "overall/avg_num_lm_steps" => mean(stats["episode_lm_steps"]),
      "overall/avg_num_monty_steps" => mean(stats["monty_steps"]),
      "overall/avg_num_monty_matching_steps" => mean(stats["monty_matching_steps"]),
      "overall/avg_prediction_error" => mean(stats["episode_avg_prediction_error"]),
      # NOTE, Monty's own: this does not account for several modules' run times.
      "overall/run_time" => sum(stats["run_times"]) / max(modules, 1),
      "overall/avg_episode_run_time" => mean(stats["run_times"]),
      "overall/num_episodes" => episodes,
      "episode/correct" => truthy(py_or(stats["episode_correct"], stats["episode_correct_mlh"])),
      "episode/no_match" => stats["episode_no_match"],
      "episode/confused" =>
        truthy(py_or(stats["episode_confused"], stats["episode_confused_mlh"])),
      "episode/correct_mlh" => stats["episode_correct_mlh"],
      "episode/confused_mlh" => stats["episode_confused_mlh"],
      "episode/pose_time_out" => stats["episode_pose_time_out"],
      "episode/time_out" => stats["episode_time_out"],
      "episode/used_mlh_after_time_out" =>
        truthy(py_or(stats["episode_correct_mlh"], stats["episode_confused_mlh"])),
      "episode/rotation_error" => mean(episode_errors),
      "episode/lm_steps" => stats["episode_lm_steps"] |> last_for(modules) |> max_or_nil(),
      "episode/monty_steps" => List.last(stats["monty_steps"]),
      "episode/monty_matching_steps" => List.last(stats["monty_matching_steps"]),
      "episode/mean_lm_steps_to_indv_ts" => mean(individual_ts_steps),
      "episode/run_time" => stats["run_times"] |> last_for(modules) |> max_or_nil(),
      "episode/symmetry_evidence" =>
        stats["episode_symmetry_evidence"] |> last_for(modules) |> mean(),
      "episode/goal_states_attempted" => stats["goal_states_attempted"],
      "episode/goal_state_success_rate" => stats["goal_state_success_rate"],
      "episode/avg_prediction_error" => List.last(stats["episode_avg_prediction_error"])
    }

    overall
    |> Map.merge(per_module_percentages(stats, episodes, modules))
    |> Map.merge(per_module_episode_figures(logger, mode, episode))
  end

  # The share of *modules* that did each thing, which is not the share of
  # episodes: a run where one of two modules was correct was a correct episode and
  # a 50% module.
  defp per_module_percentages(stats, episodes, modules) do
    Enum.reduce(@performance_options, %{}, fn option, percentages ->
      case option do
        "correct" ->
          Map.put(
            percentages,
            "overall/percent_correct_per_lm",
            percent(
              stats["num_correct_per_lm"] + stats["num_correct_mlh_per_lm"],
              episodes * modules
            )
          )

        "confused" ->
          Map.put(
            percentages,
            "overall/percent_confused_per_lm",
            percent(
              stats["num_confused_per_lm"] + stats["num_confused_mlh_per_lm"],
              episodes * modules
            )
          )

        counted when counted in ["correct_mlh", "confused_mlh"] ->
          percentages

        other ->
          Map.put(
            percentages,
            "overall/percent_#{other}_per_lm",
            percent(stats["num_#{other}_per_lm"], episodes * modules)
          )
      end
    end)
  end

  defp per_module_episode_figures(%__MODULE__{lms: lms} = logger, mode, episode) do
    per_module = basic(logger, mode, "stats") |> Map.get(episode, %{})

    Enum.reduce(lms, %{}, fn lm, figures ->
      module = Map.get(per_module, lm, %{})

      figures
      |> Map.put("#{lm}/episode/steps_to_individual_ts", module["individual_ts_reached_at_step"])
      |> Map.put(
        "#{lm}/episode/individual_ts_rotation_error",
        module["individual_ts_rotation_error"]
      )
      |> then(fn figures ->
        if is_map_key(module, "episode_avg_prediction_error"),
          do:
            Map.put(
              figures,
              "#{lm}/episode/avg_prediction_error",
              module["episode_avg_prediction_error"]
            ),
          else: figures
      end)
    end)
  end

  defp percent(_count, 0), do: nil

  defp percent(count, episodes), do: count / episodes * 100

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp sum([]), do: 0
  defp sum(values), do: Enum.sum(values)

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  # Monty's `stats["x"][-len(self.lms):]`: what the most recent episode's modules
  # did, not the whole run's.
  defp last_for(_values, 0), do: []
  defp last_for(values, count), do: Enum.take(values, -count)

  # Python's `a or b` on the 0/1 counters Monty keeps: the first that is set.
  defp py_or(0, other), do: other
  defp py_or(value, _other), do: value

  # Python's `1 or 0` reads as a boolean in a log; a JSON reader expects `true`.
  defp truthy(0), do: false
  defp truthy(nil), do: false
  defp truthy(_anything_else), do: true

  # -- the pool --------------------------------------------------------------

  defp empty_data do
    basic =
      Map.new(
        for mode <- @modes, kind <- ~w(stats overall_stats targets actions timing) do
          {"#{mode}_#{kind}", %{}}
        end
      )

    %{"BASIC" => basic, "DETAILED" => %{}}
  end

  defp basic(%__MODULE__{data: data}, mode, kind) do
    data |> Map.fetch!("BASIC") |> Map.fetch!("#{mode}_#{kind}")
  end

  defp put_basic(%__MODULE__{data: data} = logger, mode, kind, value) do
    basic = data |> Map.fetch!("BASIC") |> Map.put("#{mode}_#{kind}", value)
    %{logger | data: Map.put(data, "BASIC", basic)}
  end

  defp overall_stats(%__MODULE__{overall_train_stats: stats}, :train), do: stats
  defp overall_stats(%__MODULE__{overall_eval_stats: stats}, :eval), do: stats

  defp put_overall_stats(%__MODULE__{} = logger, :train, stats),
    do: %{logger | overall_train_stats: stats}

  defp put_overall_stats(%__MODULE__{} = logger, :eval, stats),
    do: %{logger | overall_eval_stats: stats}

  # Monty's `update_stats(append=True)`: a list that collects, and a value that is
  # only there once every module has reported.
  defp update_and_append(stats, _key, nil), do: stats
  defp update_and_append(stats, key, value), do: Map.update(stats, key, [value], &(&1 ++ [value]))

  defp replace_handler(%__MODULE__{handlers: handlers} = logger, old, new) do
    %{
      logger
      | handlers: Enum.map(handlers, fn handler -> if handler == old, do: new, else: handler end)
    }
  end

  defp initial_overall_stats do
    counters =
      Map.new(
        ~w(num_correct num_correct_mlh num_no_match num_confused num_confused_mlh
                 num_pose_time_out num_time_out num_patch_off_object num_no_label) ++
          Enum.flat_map(@performance_options, fn option ->
            ["num_#{option}", "episode_#{option}"]
          end),
        &{&1, 0}
      )

    per_module =
      Map.new(
        ~w(correct correct_mlh no_match confused confused_mlh pose_time_out time_out
           patch_off_object no_label),
        &{"num_#{&1}_per_lm", 0}
      )

    Map.merge(
      Map.merge(counters, per_module),
      %{
        "num_episodes" => 0,
        "episode_avg_prediction_error" => [],
        "episode_lm_performances" => [],
        "monty_steps" => [],
        "monty_matching_steps" => [],
        "episode_lm_steps" => [],
        "episode_lm_steps_indv_ts" => [],
        "episode_symmetry_evidence" => [],
        "rotation_errors" => [],
        "run_times" => [],
        "goal_states_attempted" => 0,
        "goal_state_success_rate" => 0
      }
    )
  end

  # -- the model -------------------------------------------------------------

  # A logger is handed the coordinator's state: it is the value that has the mode,
  # the step counts, the modules and the motor system a log is made of.
  @spec learning_modules(State.t()) :: [struct()]
  defp learning_modules(%State{learning_modules: modules}), do: Enum.map(modules, & &1.state)

  @spec steps(State.t()) :: non_neg_integer()
  defp steps(%State{step: step}), do: step

  @spec matching_steps(State.t()) :: non_neg_integer()
  defp matching_steps(%State{matching_steps: matching_steps}), do: matching_steps

  @spec actions(State.t()) :: [term()]
  defp actions(%State{motor_state: %MotorSystem{} = motor}),
    do: MotorSystem.action_sequence(motor)

  defp actions(_state), do: []

  @doc """
  The mode an episode was logged in.

  Monty reads `model.experiment_mode`; a model that has not been told one — a run
  that was never given an epoch — is evaluating, because training is the mode an
  experiment has to ask for.
  """
  @spec mode(map(), State.t()) ::
          Monty.Frameworks.Models.AbstractMontyClasses.LearningModule.mode()
  def mode(_logger_args, %State{experiment_mode: nil}), do: :eval
  def mode(_logger_args, %State{experiment_mode: mode}), do: mode

  defp episode(logger_args, mode), do: Map.get(logger_args, "#{mode}_episodes", 0)

  # Monty's `f"{mode}_episodes_to_total"`, for the handlers that key by the run's
  # episode id rather than the local one.
  defp episodes_to_total(logger_args, mode),
    do: Map.get(logger_args, "#{mode}_episodes_to_total", %{})

  # Everything the logger was told about the episode except the target, which is
  # recorded on its own: Monty's `logger_time`.
  defp timing(logger_args), do: Map.delete(logger_args, "target")
end
