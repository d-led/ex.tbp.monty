defmodule Monty.Prerequisites.Saga do
  @moduledoc """
  One prerequisite, from absent to usable, as a state machine that survives a
  restart.

  What a run needs off the disk arrives in phases — bytes over the wire, an
  archive unpacked, then a memory exported from it — and each phase can be
  interrupted by a closed tab, a reboot, a cancelled click. A sequence of steps
  in one process handles that badly: when the process ends, nothing is left to
  say how far it got, so the next attempt guesses from whatever files happen to
  be there. That guess is what told a person an archive was ready when the
  memory inside it had never been read.

  This is the same phases as a `:gen_statem` whose states are the phases, with
  two rules that make interruption harmless:

    * **Entering a state does the work of that state.** Re-entering a state
      re-runs its work, and every phase here is idempotent — the same bytes over
      the same file name, the same files out of the same archive, and an export
      that leaves a library alone when it is newer than the pickle it came from.
      So a machine that is started again simply carries on: it asks the
      filesystem where it is and enters that state, rather than trusting what it
      was doing before it died.

    * **A phase only passes when its own result says so.** The exporter reports
      each model it read, so a memory that is partly unreadable ends in
      `:failed` naming the models, not in `:done` with a red line underneath.
      Readiness and the page therefore cannot disagree: they are the same
      machine's answer.

  ```mermaid
  stateDiagram-v2
    [*] --> queued: start
    queued --> downloading: nothing on disk
    queued --> extracting: archive here, never unpacked
    queued --> exporting: unpacked, memory not read
    queued --> done: a file that needs nothing else
    downloading --> extracting: bytes verified and moved into place
    downloading --> done: a file that needs nothing else
    downloading --> failed: wrong checksum, transport error
    extracting --> exporting: unpacked
    extracting --> failed: not an archive
    exporting --> done: every model read
    exporting --> failed: a model could not be read
    done --> [*]
    failed --> [*]
    cancelled --> [*]
  ```

  `Monty.Prerequisites.Record` is what the machine writes down as it goes, and
  the filesystem is what it reads to decide where it is. Progress is broadcast
  on `"prerequisites"`, so a page does not poll and several viewers of the same
  fetch see the same numbers.
  """

  @behaviour :gen_statem

  alias Monty.Prerequisites
  alias Monty.Prerequisites.{Archive, Record}
  alias Monty.Runtime.Registry

  @topic "prerequisites"
  @broadcast_every 512 * 1024

  @type status ::
          :queued | :downloading | :extracting | :exporting | :done | :failed | :cancelled

  @type progress :: %{
          id: String.t(),
          title: String.t(),
          status: status(),
          bytes: non_neg_integer(),
          total: non_neg_integer() | nil,
          path: Path.t(),
          extracted: non_neg_integer() | nil,
          libraries: map() | nil,
          export: %{model: String.t(), index: pos_integer(), total: pos_integer()} | nil,
          error: term() | nil,
          started_at: integer() | nil,
          finished_at: integer() | nil
        }

  @typedoc """
  What the machine carries between states: the prerequisite, the process doing
  the current phase's work, and the numbers a page shows.
  """
  @type data :: %{
          prerequisite: Prerequisites.prerequisite(),
          fetcher: module(),
          path: Path.t(),
          part: Path.t(),
          bytes: non_neg_integer(),
          total: non_neg_integer() | nil,
          extracted: non_neg_integer() | nil,
          libraries: map() | nil,
          export: map() | nil,
          error: term() | nil,
          task: {pid(), reference()} | nil,
          reported_bytes: non_neg_integer(),
          started_at: integer() | nil,
          finished_at: integer() | nil,
          record: map()
        }

  # -- client API -----------------------------------------------------------

  @doc "The PubSub topic progress is broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Starts (or finds) the machine for a prerequisite.

  Starting the same prerequisite twice returns the running machine: two writers
  to one `.part` file is a corruption, not a speed-up. A machine that has
  finished is history, so the next request starts a fresh one — which is how a
  click after a failure retries, and how a deleted library is fetched again.
  """
  @spec start(Prerequisites.prerequisite(), keyword()) ::
          {:ok, pid()} | {:ok, pid(), term()} | :ignore | {:error, term()}
  def start(%{id: id} = prerequisite, opts \\ []) do
    case Registry.lookup({:download, id}) do
      [{pid, _value}] -> existing(prerequisite, pid, opts)
      [] -> start_fresh(prerequisite, opts)
    end
  end

  defp existing(prerequisite, pid, opts) do
    case running(prerequisite.id) do
      {:ok, status} when status in [:done, :failed, :cancelled] ->
        stop(pid)
        start_fresh(prerequisite, opts)

      {:ok, _running} ->
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
    :gen_statem.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp start_fresh(prerequisite, opts) do
    DynamicSupervisor.start_child(
      ExTbpMonty.PrerequisitesSupervisor,
      {__MODULE__, {prerequisite, opts}}
    )
  end

  @doc "Where a running machine for this id is registered, if any."
  @spec lookup(String.t()) :: GenServer.server() | nil
  def lookup(id) do
    case Registry.lookup({:download, id}) do
      [{_pid, _value}] -> Registry.via({:download, id})
      [] -> nil
    end
  end

  @doc "What the machine is doing, or last did."
  @spec status(GenServer.server()) :: progress()
  def status(server), do: :gen_statem.call(server, :status, :infinity)

  @doc """
  Stops a fetch, if it is still there.

  Cancelling is a person changing their mind, so a fetch that finished (or
  died) while the page was rendering must not take the page down: `:not_found`
  is the honest answer, and the page treats it as nothing to do.
  """
  @spec cancel(GenServer.server()) :: :ok | {:error, :not_found}
  def cancel(server) do
    :gen_statem.call(server, :cancel, :infinity)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  # -- callbacks ------------------------------------------------------------

  def start_link({prerequisite, opts}) do
    :gen_statem.start_link(
      Registry.via({:download, prerequisite.id}),
      __MODULE__,
      {prerequisite, opts},
      []
    )
  end

  def child_spec({prerequisite, _opts} = spec) do
    %{
      id: {:saga, prerequisite.id},
      start: {__MODULE__, :start_link, [spec]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl :gen_statem
  def callback_mode, do: [:state_functions, :state_enter]

  @impl :gen_statem
  def init({prerequisite, opts}) do
    path = Prerequisites.target_path(prerequisite)

    # The folder is made before the fetch is announced, not when the first byte
    # arrives: a target we cannot write to should fail at the click, with the
    # path in the message, rather than mid-transfer.
    with :ok <- make_directory(path) do
      data = %{
        prerequisite: prerequisite,
        fetcher: Keyword.get(opts, :fetcher, fetcher()),
        path: path,
        part: path <> ".part",
        bytes: 0,
        total: nil,
        extracted: nil,
        libraries: nil,
        export: nil,
        error: nil,
        task: nil,
        reported_bytes: 0,
        status: :queued,
        started_at: nil,
        finished_at: nil,
        record: Record.read(prerequisite) || %{}
      }

      {:ok, :queued, data, [{:next_event, :internal, :advance}]}
    end
  end

  # `path` is `Prerequisites.target_path/1`: a file name this application picks
  # under the data directory, not one a request hands in.
  # sobelow_skip ["Traversal.FileModule"]
  defp make_directory(path) do
    directory = Path.dirname(path)

    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:stop, {:cannot_create, directory, reason}}
    end
  end

  # -- the states -----------------------------------------------------------

  @doc """
  Nothing has been decided yet: ask the filesystem and enter the state it
  describes.

  This is the whole point of the machine being restartable. A record and a set
  of files are all a fresh process has, and they are enough: an archive that is
  not there must be fetched, an archive that was never unpacked must be
  unpacked, and a memory that was never read must be read.
  """
  # The machine starts here and comes back here only by being restarted, so
  # entering the state has nothing of its own to do: `:advance` is what asks the
  # filesystem, and it runs immediately after this.
  def queued(:enter, _old, data), do: {:keep_state, data}
  def queued(:internal, :advance, data), do: where(data)
  def queued(type, event, data), do: common(:queued, type, event, data)

  @doc """
  Bytes over the wire, to `<target>.part`.

  The fetch runs in its own process so this one keeps answering — that is what
  lets a page show bytes as they arrive and lets a person cancel.
  """
  def downloading(:enter, _old, data) do
    %{prerequisite: prerequisite, fetcher: fetcher, part: part} = data

    parent = self()

    {pid, reference} =
      spawn_monitor(fn ->
        result =
          fetcher.download(prerequisite.url, part, &send(parent, {:chunk, &1}),
            on_total: &send(parent, {:total, &1})
          )

        send(parent, {:finished, result})
      end)

    data = persist(%{data | task: {pid, reference}, started_at: now()}, :downloading)
    broadcast(data)
    {:keep_state, data}
  end

  def downloading(:info, {:chunk, size}, data) do
    data = %{data | bytes: data.bytes + size}

    if data.bytes - data.reported_bytes >= @broadcast_every do
      broadcast(data)
      {:keep_state, %{data | reported_bytes: data.bytes}}
    else
      {:keep_state, data}
    end
  end

  def downloading(:info, {:total, total}, data) do
    broadcast(%{data | total: total})
    {:keep_state, %{data | total: total}}
  end

  # Bytes are only a download once they are the bytes that were asked for: the
  # file is checked, then moved into place under its real name. A `.part` that
  # is wrong is removed, never renamed.
  def downloading(:info, {:finished, {:ok, bytes}}, data) do
    case verify_checksum(data.part, data.prerequisite[:sha256]) do
      :ok -> move_into_place(%{data | bytes: bytes, task: nil})
      {:error, reason} -> {:next_state, :failed, blamed(data, reason)}
    end
  end

  def downloading(:info, {:finished, {:error, reason}}, data) do
    {:next_state, :failed, blamed(data, reason)}
  end

  def downloading(type, event, data), do: common(:downloading, type, event, data)

  @doc """
  An archive that Monty's docs say to unpack, unpacked.

  Unpacking is a phase rather than a step a person is left to remember: the
  archive is not a prerequisite until its contents are where a run looks.
  """
  def extracting(:enter, _old, data) do
    parent = self()
    path = data.path

    {pid, reference} =
      spawn_monitor(fn -> send(parent, {:extracted, Archive.extract(path)}) end)

    data = persist(%{data | task: {pid, reference}}, :extracting)
    broadcast(data)
    {:keep_state, data}
  end

  def extracting(:info, {:extracted, {:ok, files}}, data) do
    # Written down before the export begins: an unpacking that is remembered is
    # an unpacking a restarted machine does not have to repeat.
    data = persist(%{data | extracted: files, task: nil}, :extracting, %{"unpacked" => true})
    {:next_state, memory_phase(data.prerequisite), data}
  end

  def extracting(:info, {:extracted, {:error, reason}}, data) do
    {:next_state, :failed, blamed(data, reason)}
  end

  def extracting(type, event, data), do: common(:extracting, type, event, data)

  @doc """
  The pretrained memory written out as the libraries a run reads.

  A run reads libraries, not pickles, so a fetch that stopped at the unpacking
  leaves the first run with nothing to recognise with. The export is scoped to
  what this archive carries — asking it to look at every model on the machine
  was how a fetch of the object meshes ended up exporting somebody's
  pretrained models.

  The phase has nothing on the wire to measure, so it reports the model it is
  reading; and its outcome is the verdict: every model read is `:done`, one
  that could not be read is `:failed` naming it.
  """
  def exporting(:enter, _old, data) do
    parent = self()
    root = Prerequisites.where_it_lands(data.prerequisite)
    libraries = Monty.Studio.Memory.libraries_dir()
    on_progress = fn progress -> send(parent, {:exporting, progress}) end

    {pid, reference} =
      spawn_monitor(fn ->
        send(
          parent,
          {:exported, Monty.Studio.Pretrained.sync(root, libraries, on_progress: on_progress)}
        )
      end)

    data = persist(%{data | task: {pid, reference}, export: nil}, :exporting)
    broadcast(data)
    {:keep_state, data}
  end

  def exporting(:info, {:exporting, progress}, data) do
    broadcast(%{data | export: progress})
    {:keep_state, %{data | export: progress}}
  end

  def exporting(:info, {:exported, %{failed: []} = outcome}, data) do
    {:next_state, :done, %{data | libraries: outcome, task: nil, export: nil}}
  end

  # The archive is here and unpacked, and part of the memory inside it could not
  # be read. That is not a fetch that finished: a run of one of those models has
  # nothing to recognise with, and the page must say so in the same breath as
  # the model's name.
  def exporting(:info, {:exported, %{failed: failed} = outcome}, data) do
    unreadable = Enum.map(failed, fn {model, _reason} -> model end)

    {:next_state, :failed,
     blamed(%{data | libraries: outcome, task: nil, export: nil}, {:unread_memory, unreadable})}
  end

  def exporting(type, event, data), do: common(:exporting, type, event, data)

  @doc "Everything this prerequisite names is on the disk, and was checked."
  def done(:enter, _old, data) do
    data = persist(%{data | finished_at: now(), error: nil}, :done)
    broadcast(data)
    {:keep_state, data}
  end

  def done(type, event, data), do: common(:done, type, event, data)

  @doc """
  A phase could not be completed; `error` says which and why.

  The partial file is removed rather than left to look like progress: a `.part`
  is not a prerequisite, and the next attempt starts from bytes it can trust.
  """
  # The partial file this machine itself wrote, at a name built from the
  # manifest — never a path a request hands in.
  # sobelow_skip ["Traversal.FileModule"]
  def failed(:enter, _old, data) do
    File.rm(data.part)
    data = persist(%{data | task: nil, finished_at: now()}, :failed)
    broadcast(data)
    {:keep_state, data}
  end

  def failed(type, event, data), do: common(:failed, type, event, data)

  @doc "A person stopped it. Nothing of the fetch is left behind."
  # The partial file of the fetch this machine was doing, named from the
  # prerequisite it belongs to.
  # sobelow_skip ["Traversal.FileModule"]
  def cancelled(:enter, _old, data) do
    if data.task, do: stop_task(data.task)
    File.rm(data.part)

    data = persist(%{data | task: nil, error: nil, finished_at: now()}, :cancelled)
    broadcast(data)
    {:keep_state, data}
  end

  def cancelled(type, event, data), do: common(:cancelled, type, event, data)

  # -- what every state answers ---------------------------------------------

  defp common(_state, {:call, from}, :status, data) do
    {:keep_state, data, [{:reply, from, public(data)}]}
  end

  defp common(state, {:call, from}, :cancel, data), do: cancel(state, from, data)

  defp common(state, :info, message, data), do: unexpected(state, message, data)

  # Cancelling is a person changing their mind. A machine that has already
  # finished has nothing to stop, so it answers and stays where it is; anything
  # else enters `:cancelled`, whose entry cleans up.
  defp cancel(state, from, data) do
    if state in [:done, :failed, :cancelled],
      do: {:keep_state, data, [{:reply, from, :ok}]},
      else: {:next_state, :cancelled, data, [{:reply, from, :ok}]}
  end

  # A phase's process dying without a result is that phase failing — the finished
  # message arrives first in the normal case. Progress that arrives after the
  # phase it belongs to is not this machine's state to change.
  defp unexpected(state, {:DOWN, reference, :process, pid, reason}, data) do
    if state in [:downloading, :extracting, :exporting] and data.task == {pid, reference},
      do: {:next_state, :failed, blamed(data, reason)},
      else: {:keep_state, data}
  end

  defp unexpected(_state, _message, data), do: {:keep_state, data}

  # -- moving on ------------------------------------------------------------

  # Where the machine is now, asked of the filesystem rather than remembered:
  # this is the answer a restarted process gives, and the answer a first one
  # gives too.
  defp where(data), do: {:next_state, phase(data.prerequisite, data.path, data.record), data}

  @doc """
  Whether there is nothing left for a machine to do for this prerequisite.

  The same derivation the machine itself uses, asked without starting one —
  which is how a boot decides what to fetch. Only a prerequisite that is a
  single file can be ready: an archive always has its memory to verify, and
  verifying it is how a library that was deleted, or made by an older version,
  comes back without anybody being told about it.

  Reads the record, so it costs one small file per prerequisite.
  """
  @spec ready?(Prerequisites.prerequisite()) :: boolean()
  def ready?(prerequisite) do
    phase(prerequisite, Prerequisites.target_path(prerequisite), Record.read(prerequisite) || %{}) ==
      :done
  end

  # A prerequisite that is one file is done when the file is there.
  defp phase(%{extract: false}, path, _record) do
    if File.exists?(path), do: :done, else: :downloading
  end

  # An archive is fetched, unpacked, then read — and each of those can be the
  # one that is missing.
  defp phase(prerequisite, path, record) do
    cond do
      not File.exists?(path) and not Prerequisites.present?(prerequisite) -> :downloading
      # The archive was deleted after it was unpacked. What it filled is still
      # there, so what is left is to read it.
      not File.exists?(path) -> memory_phase(prerequisite)
      not unpacked?(prerequisite, record) -> :extracting
      true -> memory_phase(prerequisite)
    end
  end

  # Reading the memory is only work when a library is missing or older than the
  # pickle it came from. Asking the exporter is a walk of mtimes, not a read of
  # the pickles: a machine that is whole has nothing to do, which is what makes
  # it safe for a boot to ask every prerequisite.
  defp memory_phase(prerequisite) do
    if Monty.Studio.Pretrained.pending?(Prerequisites.where_it_lands(prerequisite)),
      do: :exporting,
      else: :done
  end

  # A prerequisite that is a single file has nothing to unpack; one that arrived
  # as an archive has been unpacked when the record says a run of it completed.
  defp unpacked?(%{extract: true}, record), do: record["unpacked"] == true
  defp unpacked?(_prerequisite, _record), do: true

  defp move_into_place(data) do
    case File.rename(data.part, data.path) do
      :ok -> {:next_state, after_transfer(data), data}
      {:error, reason} -> {:next_state, :failed, blamed(data, {:cannot_move, data.path, reason})}
    end
  end

  defp after_transfer(%{prerequisite: %{extract: true}}), do: :extracting
  defp after_transfer(_data), do: :done

  defp blamed(data, reason) do
    %{data | error: reason, task: nil, finished_at: now()}
  end

  # -- what is written down -------------------------------------------------

  # One document per prerequisite, rewritten at every transition: what the state
  # is, and the two things the filesystem cannot answer — whether the unpacking
  # finished, and what the exporter made of each model.
  defp persist(data, status, extra \\ %{}) do
    record =
      data.record
      |> Map.merge(extra)
      |> Map.merge(%{
        "id" => data.prerequisite.id,
        "status" => Atom.to_string(status),
        "bytes" => data.bytes,
        "total" => data.total,
        "extracted" => data.extracted,
        "libraries" => libraries_text(data.libraries),
        "export" => data.export,
        "error" => error_text(data.error),
        "started_at" => data.started_at,
        "finished_at" => data.finished_at
      })

    Record.write(data.prerequisite, record)
    %{data | record: record, status: status}
  end

  # A term a reader can act on after a restart. The process keeps the term
  # itself for the page; this is the sentence that outlives it.
  defp error_text(nil), do: nil
  defp error_text({:unread_memory, models}), do: "unreadable memory: #{Enum.join(models, ", ")}"
  defp error_text({:cannot_extract, path, _reason}), do: "could not unpack #{path}"
  defp error_text({:cannot_move, path, _reason}), do: "could not move #{path} into place"
  defp error_text({:checksum_mismatch, actual}), do: "wrong checksum (#{actual})"
  defp error_text({:cannot_create, directory, _reason}), do: "could not create #{directory}"
  defp error_text(reason), do: inspect(reason)

  # The exporter's answer as the record can hold it. The page reads the term
  # itself — a `{model, reason}` pair per failure — but a document on disk is
  # written once and read by another version, so the names and the reasons go in
  # as text rather than as Elixir terms that only this shape can read.
  defp libraries_text(nil), do: nil

  defp libraries_text(%{} = outcome) do
    %{
      "exported" => Map.get(outcome, :exported, []),
      "current" => Map.get(outcome, :current, []),
      "failed" => Enum.map(Map.get(outcome, :failed, []), &failed_model/1)
    }
  end

  defp failed_model({model, reason}), do: %{"model" => model, "reason" => error_text(reason)}
  defp failed_model(model), do: %{"model" => to_string(model), "reason" => nil}

  # -- the rest -------------------------------------------------------------

  defp verify_checksum(_part, nil), do: :ok

  # The partial file the fetcher itself is writing; nothing else names it.
  # sobelow_skip ["Traversal.FileModule"]
  defp verify_checksum(part, expected) do
    actual =
      part
      |> File.stream!(4096)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == String.downcase(expected), do: :ok, else: {:error, {:checksum_mismatch, actual}}
  end

  defp stop_task({pid, reference}) do
    Process.demonitor(reference, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  defp fetcher do
    Application.get_env(:ex_tbp_monty, :prerequisite_fetcher, Monty.Prerequisites.HttpFetcher)
  end

  defp broadcast(data) do
    Phoenix.PubSub.broadcast(ExTbpMonty.PubSub, @topic, {:download, public(data)})
  end

  defp public(data) do
    %{
      id: data.prerequisite.id,
      title: data.prerequisite.title,
      status: data.status,
      bytes: data.bytes,
      total: data.total,
      path: data.path,
      extracted: data.extracted,
      libraries: data.libraries,
      export: data.export,
      error: data.error,
      started_at: data.started_at,
      finished_at: data.finished_at
    }
  end

  # Wall clock, not `:monotonic_time`: this value is written into a document that
  # outlives the node, and a monotonic reading means nothing in a file another
  # boot reads (`-576460698718` was a timestamp in the record).
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
