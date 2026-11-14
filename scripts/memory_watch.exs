# What is holding memory, while it is held.
#
# The studio took a machine to 20 GB and the only evidence left was 86
# `system_memory_high_watermark` alarms in a log — after the process that knew
# where the memory was had been killed. This samples while it happens.
#
#   elixir --sname memory_watch scripts/memory_watch.exs [node] [interval_s] [minutes]
#
# A node started with `--sname node1` and no `--cookie` shares this user's
# `~/.erlang.cookie`, so the probe starts with the same one and asks it directly.
#
# Every line reports two numbers that are different on purpose, because the
# difference *is* the diagnosis:
#
#   * `rss` — what the OS says every beam on this machine is holding. This is
#     the number the machine ran out of.
#   * `beam` — what the BEAM says it is holding. A NIF's own heap (CPython under
#     Pythonx, a MuJoCo model, a Rust resource) is *not* in it: the BEAM cannot
#     collect what it cannot see.
#
# So: rss climbing while beam stays flat is outside the BEAM, and no amount of
# `:erlang.garbage_collect/1` will return it. rss tracking beam is a process heap
# or a table, and the same line names the table: `run_steps` is the live steps of
# runs that have not closed, and only a path that remembers to clear one removes
# them.

[node_name | rest] =
  case System.argv() do
    [] -> ["node1"]
    argv -> argv
  end

interval = rest |> Enum.at(0, "2") |> String.to_integer()
minutes = rest |> Enum.at(1, "0") |> String.to_integer()

{:ok, host} = :inet.gethostname()
target = :"#{node_name}@#{host}"

unless Node.connect(target) do
  IO.puts("could not reach #{target}: start the node with --sname #{node_name}")
  System.halt(1)
end

table = Monty.Studio.RunStream

# `:rpc.call` answers the value itself, or `{:badrpc, reason}` — there is no
# `{:ok, _}` wrapping to unwrap.
wordsize =
  case :rpc.call(target, :erlang, :system_info, [:wordsize]) do
    words when is_integer(words) -> words
    _ -> 8
  end

{:ok, _} = Application.ensure_all_started(:logger)

defmodule Watch do
  def phrase(0), do: "-"
  def phrase(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  def phrase(bytes) when bytes >= 1_048_576, do: "#{div(bytes, 1_048_576)} MB"
  def phrase(bytes), do: "#{div(bytes, 1024)} kB"
end

sample = fn ->
  rss_kb =
    case System.cmd("ps", ["-eo", "rss,command"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, "beam.smp"))
        |> Enum.map(fn line -> line |> String.trim() |> String.split(" ", parts: 2) |> hd() |> String.to_integer() end)
        |> Enum.sum()

      _ ->
        0
    end

  # `:erlang.memory/0` answers a keyword list, not a map.
  memory =
    case :rpc.call(target, :erlang, :memory, []) do
      memory when is_list(memory) -> Map.new(memory)
      _ -> %{total: 0, processes: 0, ets: 0, binary: 0}
    end

  rows =
    case :rpc.call(target, :ets, :info, [table, :size]) do
      size when is_integer(size) -> size
      _ -> 0
    end

  held =
    case :rpc.call(target, :ets, :info, [table, :memory]) do
      words when is_integer(words) -> words * wordsize
      _ -> 0
    end

  top =
    case :rpc.call(target, Process, :list, []) do
      pids when is_list(pids) ->
        pids
        |> Enum.map(fn pid ->
          case :rpc.call(target, Process, :info, [pid, :memory]) do
            {:memory, memory} when is_integer(memory) -> {pid, memory}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&elem(&1, 1), :desc)
        |> Enum.take(3)
        |> Enum.map_join(" ", fn {pid, memory} ->
          tag =
            case :rpc.call(target, Process, :info, [pid, :registered_name]) do
              {_, name} when is_atom(name) -> inspect(name)
              _ -> inspect(pid)
            end

          "#{tag}=#{Watch.phrase(memory)}"
        end)

      _ ->
        "?"
    end

  IO.puts(
    "#{Calendar.strftime(DateTime.utc_now(), "%H:%M:%S")} " <>
      "rss=#{Watch.phrase(rss_kb * 1024)} " <>
      "beam=#{Watch.phrase(memory[:total])} " <>
      "(processes=#{Watch.phrase(memory[:processes])} ets=#{Watch.phrase(memory[:ets])} binary=#{Watch.phrase(memory[:binary])}) " <>
      "run_steps=#{rows} rows, #{Watch.phrase(held)} | top: #{top}"
  )
end

IO.puts("watching #{target} every #{interval}s#{if minutes > 0, do: " for #{minutes} min", else: ""}")
stop_at = System.monotonic_time(:second) + minutes * 60

Stream.repeatedly(fn ->
  sample.()
  Process.sleep(interval * 1000)
  System.monotonic_time(:second)
end)
|> Enum.find(fn now -> minutes > 0 and now >= stop_at end)
