defmodule Monty.Studio.RunLimits do
  @moduledoc """
  What a run may hold before it is stopped, and the one flag that stops a single
  process running away.

  Two ceilings, both read from `Monty.Studio.Settings` at the moment they are
  used, so a change takes effect at the next run without a restart:

  * **A process's heap** (`run_max_heap_mb`). Applied with
    `:erlang.system_flag(:max_heap_size, ...)`, which is what `+hmax` sets: every
    process started afterwards carries the limit, and one that passes it is
    killed. This is the guard for a single runaway process — a learning module
    that samples itself into a heap nobody can collect.
  * **The whole VM** (`run_max_memory_mb`). A run is stopped when the machine
    holds more than this. It is read from the operating system rather than from
    the BEAM, because the memory that took a workstation down is not always the
    BEAM's: a NIF's own heap (MuJoCo, a GL context, CPython under Pythonx) is
    invisible to `:erlang.memory/1` and no amount of collection returns it.

  Neither is a wall, and both gaps are worth knowing:

  * `max_heap_size` counts a process's heap and stack. A **large binary** (over
    64 bytes) lives in a shared off-heap heap, so a process can hold a gigabyte
    of them without tripping the flag — `:erlang.memory(:binary)` is the number
    that sees those, and the VM ceiling above is what catches them.
  * The VM ceiling is a snapshot taken every few seconds, so it stops a run just
    after it passed the line, not before.

  Together they answer the only question that matters on a 16 GB laptop: can one
  experiment take the machine down? With a ceiling it cannot — it is stopped, and
  the run says so.
  """

  require Logger

  alias Monty.Studio.Settings

  @heap_setting "run_max_heap_mb"
  @vm_setting "run_max_memory_mb"

  # Six seconds is well under the time a runaway needs to matter and well over
  # the cost of one `ps`; a sampler that ran per step would be a cost on the
  # thing it is measuring.
  @interval_ms 6_000

  @doc "The setting a process's heap ceiling is read from."
  @spec heap_setting() :: String.t()
  def heap_setting, do: @heap_setting

  @doc "The setting a run's whole-VM ceiling is read from."
  @spec vm_setting() :: String.t()
  def vm_setting, do: @vm_setting

  @doc """
  The `max_heap_size` flag for a ceiling in megabytes.

  Words, because that is the unit ERTS counts in, and `kill: true` with the
  error logger on, because a process that passes its ceiling is a defect worth a
  line in the log rather than a silence.
  """
  @spec heap_flag(number()) :: %{
          size: non_neg_integer(),
          error_logger: boolean(),
          kill: boolean()
        }
  def heap_flag(megabytes) when is_number(megabytes) and megabytes > 0 do
    %{
      size: trunc(megabytes * 1024 * 1024 / :erlang.system_info(:wordsize)),
      error_logger: true,
      kill: true
    }
  end

  @doc """
  Applies the heap ceiling to every process started from now on — and to this one.

  `:erlang.system_flag/2` is the runtime's own default for new processes — the
  same switch `+hmax` flips at boot — so no process the studio starts after this
  call can pass it, including the learning and sensor modules a run builds.

  **The process asking for it is the one that needs it most.** A flag set now is
  a default for processes created *later*, and the run performs its steps in the
  worker that called this function: that worker was created by the queue before
  the flag existed. A page-started run of the 480 × 640 image world therefore
  grew past 4 GB untouched — the one ceiling that would have stopped it did not
  apply to the process holding the frames — and `docs/monty-differences.md` §2.41
  has the measurement. `Process.flag/2` covers it, and `megabytes` is a seam for a
  test that has no business allocating four gigabytes.
  """
  @spec apply_heap_limit(number()) :: :ok
  def apply_heap_limit(megabytes \\ nil) do
    flag = (megabytes || Settings.get(@heap_setting)) |> heap_flag()
    # `system_flag/2` answers the flag it replaced — `size: 0` when nothing had
    # set one — and the answer is not the point.
    _for_new_processes = :erlang.system_flag(:max_heap_size, flag)
    bound(flag)
  end

  @doc """
  Bounds this process to `flag`, which is `heap_flag/1`'s answer.

  Its own function because it is its own question, and because setting the
  *default* is a change to the whole VM: a test of the two together would leave
  every process created afterwards in the test run carrying the ceiling it used.
  """
  @spec bound(map()) :: :ok
  def bound(flag) do
    _was = Process.flag(:max_heap_size, flag)
    :ok
  end

  @doc """
  The processes holding the most memory, heaviest first.

  Asked when a ceiling is crossed, so the line a person reads names what took the
  memory rather than only that something did: a run of the 480 × 640 image world
  once reached tens of gigabytes, and the only trace of *which* process held them
  was a number. `count` is how many to answer.
  """
  @spec heaviest(pos_integer()) :: [%{pid: pid(), bytes: non_neg_integer(), label: String.t()}]
  def heaviest(count \\ 5) do
    :erlang.processes()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:memory, :registered_name, :current_function]) do
        [memory: bytes, registered_name: name, current_function: function] ->
          [%{pid: pid, bytes: bytes, label: label(name, function)}]

        nil ->
          []
      end
    end)
    |> Enum.sort_by(& &1.bytes, :desc)
    |> Enum.take(count)
  end

  # A process nobody registered is named by where it is, which is the answer that
  # says what it is: a module and function rather than a pid. A generator that is
  # waiting is `gen_server:loop`, which is worth knowing too.
  defp label([], {module, function, _arity}), do: "#{inspect(module)}.#{function}"
  defp label([], function), do: inspect(function)
  defp label(name, _function), do: inspect(name)

  @doc """
  Watches a run and stops it when the machine holds more than its ceiling.

  The watcher is linked to the process performing the run, so it ends when that
  process does — a finished, stopped or crashed run leaves no sampler behind.
  The ceiling is read here, in the caller, and handed over: a run's budget is a
  decision taken when it starts, and a background sampler has no business
  reading the database.

  `:held`, `:allowed`, `:stop` and `:interval` are seams for a test: a watcher
  whose ceiling can only be crossed by a real runaway would have no case that
  runs in a second, and letting a test hand it a number is the same dependency
  the run hands it.
  """
  @spec watch(binary(), keyword()) :: pid()
  def watch(run_id, opts \\ []) do
    held = Keyword.get(opts, :held, &held_bytes/0)
    allowed = Keyword.get_lazy(opts, :allowed, &allowed_mb/0)
    stop = Keyword.get(opts, :stop, &stop_run/1)
    interval = Keyword.get(opts, :interval, @interval_ms)

    spawn_link(fn -> watch_loop(run_id, held, stop, interval, allowed) end)
  end

  @doc "What this run's VM may hold, in megabytes."
  @spec allowed_mb() :: pos_integer()
  def allowed_mb, do: Settings.get(@vm_setting)

  defp watch_loop(run_id, held, stop, interval, allowed) do
    Process.sleep(interval)
    # The reading, not the reader: keeping the function is what lets the loop
    # ask again on the next tick.
    now = held.()

    if exceeded?(allowed, now) do
      Logger.error(
        "run #{run_id} passed its memory ceiling " <>
          "(#{megabytes(now)} MB held, #{allowed} MB allowed) — asking it to stop. " <>
          "The heaviest processes: " <> heaviest_line()
      )

      stop.(run_id)
    else
      watch_loop(run_id, held, stop, interval, allowed)
    end
  end

  defp heaviest_line do
    Enum.map_join(heaviest(), ", ", fn held ->
      "#{held.label} (#{inspect(held.pid)}) #{megabytes(held.bytes)} MB"
    end)
  end

  @doc """
  Whether `bytes` held is past a ceiling given in megabytes.
  """
  @spec exceeded?(number(), number()) :: boolean()
  def exceeded?(megabytes, bytes), do: bytes > megabytes * 1024 * 1024

  @doc """
  What this VM holds, as the operating system counts it.

  The OS is asked rather than the BEAM for a reason: a run that took a machine
  down held the memory, and the BEAM's own total does not include the heap of a
  NIF. `ps` is asked last, on a machine that has no `/proc`, and a VMS that will
  answer neither falls back to the BEAM's own number — a smaller ceiling than the
  real one is still a ceiling.
  """
  @spec held_bytes() :: non_neg_integer()
  def held_bytes do
    # `System.pid/0` is this VM's process id, not the OS's idea of a name.
    case System.cmd("ps", ["-o", "rss=", "-p", System.pid()], stderr_to_stdout: true) do
      {output, 0} -> kilobytes(output)
      _will_not_answer -> :erlang.memory(:total)
    end
  rescue
    # A machine with no `ps` at all: the BEAM's own number, which is a floor.
    _no_ps -> :erlang.memory(:total)
  end

  defp kilobytes(output) do
    case Integer.parse(String.trim(output)) do
      {kilobytes, _rest} -> kilobytes * 1024
      :error -> :erlang.memory(:total)
    end
  end

  @doc "A byte count as whole megabytes, for a sentence."
  @spec megabytes(number()) :: non_neg_integer()
  def megabytes(bytes), do: trunc(bytes / 1024 / 1024)

  # The stop is the run's own: it asks the worker at its next step boundary, which
  # records an ending instead of dying in the middle of a step.
  defp stop_run(run_id), do: Monty.Studio.Jobs.Run.stop(run_id)

  @doc """
  Runs a step, and answers why it ended instead of exiting.

  A step is a call to the process that holds the model, and that process can be
  killed by its heap ceiling. A killed process takes the caller's call with it:
  the exit is not an exception, so an uncaught one ends the VM — which is how a
  run's log came to stop at a step, with no summary and nothing said (§2.35).
  Caught here, the death becomes the sentence below.
  """
  @spec watch_step((-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def watch_step(work) when is_function(work, 0) do
    {:ok, work.()}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "What to say when a run's process ended instead of answering."
  @spec stopped_sentence(term()) :: String.t()
  def stopped_sentence(:killed) do
    "its process was killed by the runtime, which is what a heap ceiling does. " <>
      "`#{@heap_setting}` bounds one process, and a killed process says nothing " <>
      "itself, so the run stopped here: nothing it had not already written is " <>
      "kept. Raise that setting, or run fewer steps, and it will run to its end."
  end

  def stopped_sentence({%_{} = exception, stacktrace} = _crash) when is_list(stacktrace),
    do: Exception.format(:error, exception, stacktrace)

  # A worker killed mid-step takes its caller's `GenServer.call` with it, and the
  # request that call carried is a step's whole observation — printing it would
  # bury the sentence. The worker's death is logged where it happened, by the
  # runtime that logged it, so the sentence points there instead.
  def stopped_sentence({:shutdown, {GenServer, :call, [server | _rest]}} = _call) do
    "the step worker it was waiting for stopped mid-call (#{inspect(server)}), " <>
      "and what stopped it is the line logged above"
  end

  def stopped_sentence(reason), do: "its process ended with #{inspect(reason)}"
end
