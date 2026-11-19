# What a pretrained library costs once it is Elixir terms.
#
#   mix run --no-start scripts/measure_library_memory.exs [release] [model]
#   mix run --no-start scripts/measure_library_memory.exs pretrained_ycb_v10 surf_agent_1lm_77obj
#
# `Monty.Studio.Memory` reads the same gzipped JSONL Monty's libraries are
# exported as. This says what a library costs on disk, as text, and as the terms
# this port holds it in. The last number is the one a run's heap ceiling has to
# fit, and the ratio to the text is the price of the representation.
#
# Measured 2026-11-16 on an M-series laptop: `pretrained_ycb_v10/surf_agent_1lm_77obj`
# is 23.4 MB gzipped, 57.8 MB of text, and 372 MB of VM memory once loaded.

alias Monty.Studio.Memory

release = Enum.at(System.argv(), 0) || "pretrained_ycb_v10"
model = Enum.at(System.argv(), 1) || "surf_agent_1lm_77obj"

path = Path.join([Monty.Paths.libraries(), release, model <> ".jsonl.gz"])

case File.read(path) do
  {:error, :enoent} ->
    IO.puts("no library at #{path} — fetch it with the prerequisites task first")

  {:ok, raw} ->
    text = :zlib.gunzip(raw)

    measure = fn -> :erlang.garbage_collect() end

    measure.()
    {:ok, memory} = Memory.load(model, release)

    # The value's own size in heap words, which is exact — the VM's total memory
    # before and after a load depends on how much of the heap has been swept, and
    # two runs of the same load differ by a factor of two because of it.
    words = :erts_debug.flat_size(memory)

    IO.puts("""
    library:   #{release}/#{model}
    on disk:   #{Float.round(byte_size(raw) / 1.0e6, 1)} MB (gzipped)
    as text:   #{Float.round(byte_size(text) / 1.0e6, 1)} MB
    as terms:  #{Float.round(words * 8 / 1.0e6, 1)} MB of heap words — \
    #{(words * 8 / byte_size(text)) |> Float.round(1)} times the text
    """)
end
