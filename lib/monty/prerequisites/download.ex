defmodule Monty.Prerequisites.Download do
  @moduledoc """
  One prerequisite being fetched, with progress anyone can watch.

  The download runs in a separate process while this process keeps answering —
  that is what lets the UI show bytes as they arrive and lets a person cancel.
  Bytes go to `<target>.part`; the file is moved into place only after the
  bytes and, when the manifest names one, the checksum match. A failed or
  cancelled download leaves nothing behind that looks finished.

  Progress is broadcast on `"prerequisites"`, so a page does not have to poll
  and several viewers of the same download see the same numbers.
  """

  use GenServer

  alias Monty.Prerequisites
  alias Monty.Runtime.Registry

  @topic "prerequisites"
  @broadcast_every 512 * 1024

  @type status :: :queued | :downloading | :done | :failed | :cancelled

  @type progress :: %{
          id: String.t(),
          title: String.t(),
          status: status(),
          bytes: non_neg_integer(),
          total: non_neg_integer() | nil,
          path: Path.t(),
          error: term() | nil,
          started_at: integer() | nil,
          finished_at: integer() | nil
        }

  # -- client API -----------------------------------------------------------

  @doc "The PubSub topic progress is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Starts (or finds) the download for a prerequisite.

  Starting the same prerequisite twice returns the running process: two
  writers to one `.part` file is a corruption, not a speed-up.
  """
  @spec start(Prerequisites.prerequisite(), keyword()) ::
          {:ok, pid()} | {:ok, pid(), term()} | :ignore | {:error, term()}
  def start(%{id: id} = prerequisite, opts \\ []) do
    # A click is a person, not a test: nothing here may raise. A registry entry
    # can outlive its process by a moment, and a dead pid between the lookup and
    # the call used to take the whole page down with it.
    case Registry.lookup({:download, id}) do
      [{pid, _value}] -> existing(id, pid, prerequisite, opts)
      [] -> start_fresh(prerequisite, opts)
    end
  end

  defp existing(id, pid, prerequisite, opts) do
    case running(id) do
      {:ok, status} when status in [:done, :failed, :cancelled] ->
        # A finished attempt is history, not a download in progress: stop it so
        # the next click really fetches again.
        stop(pid)
        start_fresh(prerequisite, opts)

      {:ok, _status} ->
        {:ok, pid}

      :gone ->
        start_fresh(prerequisite, opts)
    end
  end

  defp running(id) do
    {:ok, status(Registry.via({:download, id})).status}
  catch
    :exit, _reason -> :gone
  end

  defp stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp start_fresh(prerequisite, opts) do
    DynamicSupervisor.start_child(
      ExTbpMonty.PrerequisitesSupervisor,
      {__MODULE__, {prerequisite, opts}}
    )
  end

  @doc "Where a running download for this id is registered, if any."
  @spec lookup(String.t()) :: GenServer.server() | nil
  def lookup(id) do
    case Registry.lookup({:download, id}) do
      [{_pid, _value}] -> Registry.via({:download, id})
      [] -> nil
    end
  end

  @spec status(GenServer.server()) :: progress()
  def status(server), do: GenServer.call(server, :status, :infinity)

  @doc """
  Stops a download, if it is still there.

  Cancelling is a person changing their mind, so a download that finished (or
  died) while the page was rendering must not take the page down: `:not_found`
  is the honest answer, and the page treats it as nothing to do.
  """
  @spec cancel(GenServer.server()) :: :ok | {:error, :not_found}
  def cancel(server) do
    GenServer.call(server, :cancel, :infinity)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  # -- callbacks ------------------------------------------------------------

  def start_link({prerequisite, opts}) do
    GenServer.start_link(__MODULE__, {prerequisite, opts},
      name: Registry.via({:download, prerequisite.id})
    )
  end

  def child_spec({prerequisite, _opts} = spec) do
    %{
      id: {:download, prerequisite.id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init({prerequisite, opts}) do
    path = Prerequisites.target_path(prerequisite)

    # The folder is made before the download is announced, not when the first
    # byte arrives: a target we cannot write to should fail at the click, with
    # the path in the message, rather than mid-transfer.
    with :ok <- make_directory(path) do
      {:ok, state(prerequisite, opts, path), {:continue, :download}}
    end
  end

  defp make_directory(path) do
    directory = Path.dirname(path)

    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:stop, {:cannot_create, directory, reason}}
    end
  end

  defp state(prerequisite, opts, path) do
    %{
      prerequisite: prerequisite,
      fetcher: Keyword.get(opts, :fetcher, fetcher()),
      status: :queued,
      bytes: 0,
      total: nil,
      error: nil,
      # The destination is decided once, when the download starts: a change to
      # the environment variable afterwards must not move the file elsewhere.
      path: path,
      part: path <> ".part",
      task: nil,
      reported_bytes: 0,
      started_at: nil,
      finished_at: nil
    }
  end

  @impl true
  def handle_continue(:download, state) do
    %{prerequisite: prerequisite, fetcher: fetcher, part: part} = state

    parent = self()

    {pid, reference} =
      spawn_monitor(fn ->
        result =
          fetcher.download(prerequisite.url, part, &send(parent, {:chunk, &1}),
            on_total: &send(parent, {:total, &1})
          )

        send(parent, {:finished, result})
      end)

    state = %{state | status: :downloading, task: {pid, reference}, started_at: now()}
    broadcast(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call(:cancel, _from, state) do
    if state.status in [:done, :failed, :cancelled] do
      {:reply, :ok, state}
    else
      if state.task, do: stop_task(state.task)
      File.rm(state.part)

      state = %{state | status: :cancelled, finished_at: now()}
      broadcast(state)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:chunk, size}, state) do
    state = %{state | bytes: state.bytes + size}

    if state.bytes - state.reported_bytes >= @broadcast_every do
      broadcast(state)
      {:noreply, %{state | reported_bytes: state.bytes}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:total, total}, state) do
    broadcast(%{state | total: total})
    {:noreply, %{state | total: total}}
  end

  def handle_info({:finished, {:ok, bytes}}, state) do
    finish(state, bytes)
  end

  def handle_info({:finished, {:error, reason}}, state) do
    {:noreply, fail(state, reason)}
  end

  def handle_info({:DOWN, reference, :process, pid, reason}, %{task: {pid, reference}} = state) do
    # The finished message arrives first in the normal case; an exit without
    # one is the downloader itself dying.
    if state.status == :downloading, do: {:noreply, fail(state, reason)}, else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- finishing ------------------------------------------------------------

  defp finish(state, bytes) do
    case verify_checksum(state.part, state.prerequisite[:sha256]) do
      :ok -> {:noreply, complete(state, bytes)}
      {:error, reason} -> {:noreply, fail(state, reason)}
    end
  end

  defp complete(state, bytes) do
    File.rename!(state.part, state.path)

    state = %{state | status: :done, bytes: bytes, finished_at: now()}
    broadcast(state)
    state
  end

  defp verify_checksum(_part, nil), do: :ok

  defp verify_checksum(part, expected) do
    actual =
      part
      |> File.stream!(4096)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == String.downcase(expected), do: :ok, else: {:error, {:checksum_mismatch, actual}}
  end

  defp fail(state, reason) do
    File.rm(state.part)
    state = %{state | status: :failed, error: reason, finished_at: now()}
    broadcast(state)
    state
  end

  defp stop_task({pid, reference}) do
    Process.demonitor(reference, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  defp fetcher do
    Application.get_env(:ex_tbp_monty, :prerequisite_fetcher, Monty.Prerequisites.HttpFetcher)
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, @topic, {:download, public(state)})
  end

  defp public(state) do
    %{
      id: state.prerequisite.id,
      title: state.prerequisite.title,
      status: state.status,
      bytes: state.bytes,
      total: state.total,
      path: state.path,
      error: state.error,
      started_at: state.started_at,
      finished_at: state.finished_at
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
