# What one learning module costs when it is handed a pretrained library.
#
#   MIX_ENV=test mix run --no-start scripts/measure_module_memory.exs
#   MIX_ENV=test mix run --no-start scripts/measure_module_memory.exs base_77obj_dist_agent pretrained_ycb_v10 surf_agent_1lm_77obj
#
# A run of `base_77obj_dist_agent` is killed inside its first episode with two
# processes past the studio's heap ceiling, while the library file is 23 MB
# gzipped. This reports both numbers a person is tempted to quote, and they do
# not agree:
#
#   * `:erts_debug.flat_size/1` per field, which counts a shared substructure
#     once for every path that reaches it — the updater, the goal generator and
#     the module all point at the same library, so it reads as a multiple;
#   * the process' own heap after a collect, which is what a ceiling has to fit.
#
# The second is the honest one. Measured 2026-11-16: the library costs 213 MB of
# heap, and the module adds nothing measurable on top of it.

alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Studio.{Memory, Setup}

experiment = Enum.at(System.argv(), 0) || "base_77obj_dist_agent"
release = Enum.at(System.argv(), 1) || "pretrained_ycb_v10"
model = Enum.at(System.argv(), 2) || "surf_agent_1lm_77obj"

megabytes = fn term -> :erts_debug.flat_size(term) * 8 / 1.0e6 end
heap = fn -> :erlang.process_info(self(), :memory) |> elem(1) |> Kernel./(1.0e6) end
round = fn number -> Float.round(number, 1) end

{:ok, setup} = Setup.from_experiment(experiment)
[spec | _rest] = setup.learning_modules
config = Map.get(spec, :config) || %{}

:erlang.garbage_collect()
before = heap.()

{:ok, memory} = Memory.load(model, release)
:erlang.garbage_collect()
with_library = heap.()

{:ok, lm} = EvidenceGraphLM.from_config(config, memory: memory)
:erlang.garbage_collect()
with_module = heap.()

IO.puts("""
#{experiment}, #{release}/#{model}

this process holds
  before anything:                #{round.(before)} MB
  with the library:               #{round.(with_library)} MB (+#{round.(with_library - before)})
  with one module on top:         #{round.(with_module)} MB (+#{round.(with_module - with_library)})

the module, by flat size — shared terms counted once per path, so not the heap:
  graph_memory:                   #{round.(megabytes.(lm.graph_memory))} MB
  hypotheses_updater:             #{round.(megabytes.(lm.hypotheses_updater))} MB
  gsg:                            #{round.(megabytes.(lm.gsg))} MB
""")
