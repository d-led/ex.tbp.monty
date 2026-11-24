defmodule Monty.Studio.Endless do
  @moduledoc """
  The two switches an open-ended run carries: whether it has an ending at all,
  and whether it is learning right now.

  A normal run ends when the experiment's recognition policy says so, or when
  the step budget runs out; both live in one place (`Monty.Studio.Run.finished?/1`).
  A run started with `"endless" => true` in its inputs is not asked that
  question, so its episode steps until a person presses Stop. The policy is not
  replaced, it is ignored — nothing else about the step changes.

  Training is the second switch, and it can be flipped while the run steps. It
  is not a field of the episode (an episode's mode is fixed when it starts), so
  it is kept here and told to the model before each step
  (`sync/3`). Turning it off asks the module to write what it learned first:
  `EvidenceGraphLM.update_ltm_from_stm/1` writes only while the module's own
  mode is still `:train`, so the order `update_ltm` then `:eval` is the whole
  meaning of "stop learning".

  The state lives in one ETS row per run, beside `Monty.Studio.Jobs.Stops` and
  for the same reason: the process that steps a run and the page that shows it
  are different processes, and the question "is training on" is asked by every
  step. Like `Stops`, it is node-local; a run divided across nodes is not an
  open-ended run (`Jobs.Run` ignores the switch for a part).

  ## Deleting this feature

  This module, its one child in `ExTbpMonty.Application`, its five call sites
  in `Monty.Studio.Jobs.Run`, the `endless` input shaping in
  `Monty.Studio.RunLog`, the two checkboxes in the experiment page and the
  toggle in the run page. Nothing else knows it exists: a run whose record
  carries no `"endless"` key is the run this application always started.
  """

  use GenServer

  @table __MODULE__

  @type mode :: :train | :eval

  @type settings :: %{
          endless?: boolean(),
          training: boolean() | nil,
          trained?: boolean(),
          applied: mode() | nil
        }

  @doc """
  Reads the switches a new run starts with.

  Only a record that asked to be open-ended has a row; every other run is
  absent, and absence is what `endless?/1` answers `false` to. `training`
  left out of the record is `nil` — "not decided yet" — and the first step
  decides it from the episode's own mode, so an open-ended run of a training
  config starts training and one of an evaluation config does not.
  """
  @spec start(binary(), map()) :: :ok
  def start(run_id, %{inputs: %{} = inputs}) when is_binary(run_id) do
    if inputs["endless"] == true do
      _ =
        put(run_id, %{
          endless?: true,
          training: training_from(inputs),
          trained?: inputs["training"] == true,
          applied: nil
        })

      :ok
    else
      :ok
    end
  end

  def start(_run_id, _record), do: :ok

  @doc "The switches of `run_id`, or `nil` for a run that is not open-ended."
  @spec settings(binary()) :: settings() | nil
  def settings(run_id) do
    case table() do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, run_id) do
          [{^run_id, settings}] -> settings
          [] -> nil
        end
    end
  end

  @doc "Whether the run has no termination condition."
  @spec endless?(binary()) :: boolean()
  def endless?(run_id), do: match?(%{endless?: true}, settings(run_id))

  @doc "Whether the run is learning from its steps right now."
  @spec training?(binary()) :: boolean()
  def training?(run_id), do: match?(%{training: true}, settings(run_id))

  @doc """
  Whether the run ever learned — which is what decides that its memory is
  written when it closes, even if training was switched off before the stop.
  """
  @spec trained?(binary()) :: boolean()
  def trained?(run_id), do: match?(%{trained?: true}, settings(run_id))

  @doc "Turns training on or off for a run that is open-ended."
  @spec set_training(binary(), boolean()) :: {:ok, boolean()} | {:error, :not_endless}
  def set_training(run_id, on?) when is_boolean(on?) do
    case settings(run_id) do
      nil ->
        {:error, :not_endless}

      settings ->
        put(run_id, %{settings | training: on?, trained?: settings.trained? or on?})
        {:ok, on?}
    end
  end

  @doc "The other of what `training?/1` answers."
  @spec toggle_training(binary()) :: {:ok, boolean()} | {:error, :not_endless}
  def toggle_training(run_id), do: set_training(run_id, not training?(run_id))

  @doc """
  The run has closed: nothing will read its switches again.

  Called where the run unregisters its owner, so a run of the same id started
  later is not handed the last one's switches.
  """
  @spec clear(binary()) :: :ok
  def clear(run_id) do
    case table() do
      :undefined -> :ok
      table -> :ets.delete(table, run_id)
    end

    :ok
  end

  @doc """
  Tells the model what the run is doing now, and answers what that is.

  Called before every step of a run. For a run that is not open-ended this is
  one missing table lookup and nothing else. For one that is, the first call
  resolves an undecided `training` from the episode's own mode, and a change
  is applied once — `update_ltm` before `:eval`, so the module writes while it
  still believes it is training.
  """
  @spec sync(binary(), atom() | String.t(), mode()) :: :ok
  def sync(run_id, model_id, episode_mode) do
    case settings(run_id) do
      %{endless?: true} = settings ->
        settings = decide_training(settings, episode_mode)
        want = if settings.training, do: :train, else: :eval
        current = settings.applied || episode_mode

        case next_mode(current, want) do
          :same -> :ok
          {:change, mode} -> apply_mode(model_id, current, mode)
        end

        _ = put(run_id, %{settings | applied: want})
        :ok

      _not_open_ended ->
        :ok
    end
  end

  @doc """
  What telling the model a mode costs: nothing when it already holds it, and
  the new mode when it does not.
  """
  @spec next_mode(mode(), mode()) :: :same | {:change, mode()}
  def next_mode(same, same), do: :same
  def next_mode(_current, want), do: {:change, want}

  # Monty writes a training episode's short-term memory into long-term memory
  # at the episode's end. An open-ended run has no end to hang that on, so the
  # switch is the boundary: leaving `:train` first writes, then changes the
  # module's mind. The other transitions are one call.
  defp apply_mode(model_id, :train, :eval) do
    :ok = Monty.Runtime.Model.update_ltm(model_id)
    Monty.Runtime.Model.set_experiment_mode(model_id, :eval)
  end

  defp apply_mode(model_id, _current, want),
    do: Monty.Runtime.Model.set_experiment_mode(model_id, want)

  # `nil` is "the record did not say", which the episode's own mode answers.
  defp decide_training(%{training: nil} = settings, episode_mode),
    do: %{settings | training: episode_mode == :train, trained?: episode_mode == :train}

  defp decide_training(settings, _episode_mode), do: settings

  # Only an explicit "yes" turns training on before the first step. "No" and
  # "not said" are the same thing here: the episode's own mode decides, so an
  # open-ended run of a training config is not silently switched to evaluation
  # by a box somebody left unticked.
  defp training_from(%{"training" => true}), do: true
  defp training_from(_inputs), do: nil

  defp put(run_id, settings) do
    case table() do
      :undefined -> :ok
      table -> :ets.insert(table, {run_id, settings})
    end
  end

  # The table is the supervised child's. A node that has run since before the
  # child existed — a dev server that has not restarted after this module
  # appeared — must still serve its pages and step its runs, so every reader and
  # writer asks whether it is there rather than assuming it.
  defp table, do: :ets.whereis(@table)

  # Not `@impl true`: `start_link` is this module's own entry point, not a
  # `GenServer` callback — the callback is the `init/1` below it.
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    _table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
