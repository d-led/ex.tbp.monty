defmodule ExTbpMonty.Desktop.ParentWatch do
  @moduledoc """
  Stops this server when the process that started it is gone.

  There is no tray icon and no menu to close, so a server that outlives its
  window is a process nobody can see: it holds the port, keeps the database
  open, and turns up in every later `ps`. The pipe the window writes to covers
  the ordinary exit. This covers what the pipe does not: a window that was
  killed outright, and a server started by hand from a shell that has since
  closed — the second is how four of them were once left running for hours.

  Why the parent pid rather than a heartbeat from the window: the window cannot
  send anything after `kill -9`, and a parent that is gone is what the operating
  system already knows. A parent that is not readable, or a system without
  `kill`, means *no answer* rather than *gone* — stopping a server whose window
  is still there would be the worse mistake of the two.
  """

  @interval_ms 2_000

  @doc """
  Watches the process that started this one, and stops the VM when it is gone.

  Returns `:ignore` when the parent cannot be read, so a supervisor simply does
  not run it; a server that cannot be watched is still a server that works.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | :ignore
  def start_link(opts \\ []) do
    case Keyword.get_lazy(opts, :parent, &parent_pid/0) do
      nil ->
        :ignore

      parent ->
        interval = Keyword.get(opts, :interval_ms, @interval_ms)
        on_gone = Keyword.get(opts, :on_gone, fn -> System.stop() end)

        # Unlinked on purpose: this task outlives nothing and must not be able to
        # take the application down with it if the check itself misbehaves.
        Task.start(fn -> watch(parent, interval, on_gone) end)
    end
  end

  @doc """
  The pid of the process that started this one, or `nil` if it cannot be read.

  An already-detached process answers `1`, which nothing can notice the death of
  and is therefore not worth watching; this reports it as `nil`.
  """
  @spec parent_pid() :: pos_integer() | nil
  def parent_pid do
    case System.cmd("ps", ["-o", "ppid=", "-p", System.pid()], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {1, ""} -> nil
          {pid, ""} when pid > 0 -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether an operating-system process is still there.

  `kill -0` checks without signalling. Anything it cannot answer — a system
  without `kill`, a permission it does not have — counts as alive.
  """
  @spec alive?(pos_integer()) :: boolean()
  def alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))
  rescue
    _ -> true
  end

  defp watch(parent, interval, on_gone) do
    Process.sleep(interval)

    if alive?(parent) do
      watch(parent, interval, on_gone)
    else
      on_gone.()
    end
  end
end
