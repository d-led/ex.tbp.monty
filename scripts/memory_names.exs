# What a trained library holds, in the terms a recognition number depends on:
# each graph, the objects it was built from, and how many nodes it carries.
#
#     MIX_ENV=test mix run --no-start scripts/memory_names.exs dogs_surf_unsupervised
#     MIX_ENV=test mix run --no-start scripts/memory_names.exs surf_agent_1lm_10distinctobj pretrained_ycb_v10
#
# The library is `priv/monty/libraries/<release>/<name>.jsonl.gz`: a run that
# trains keeps the `trained` release, Monty's own models are `pretrained_*`.
# A graph with two names is an episode that concluded it had recognised an object
# it had not seen, and then trained into the graph it mistook for it. That is the
# unsupervised rule (a `:match` appends to the recognised graph, a `:no_match`
# mints `new_object<n>`) doing its job on eight dogs that look alike from above;
# it is also why a recognition score has to say *how many* objects a graph names.
alias Monty.Frameworks.Models.GraphMatching.GraphMemory

{:ok, _} = Application.ensure_all_started(:ex_tbp_monty)

[name | rest] = System.argv()
release = List.first(rest, "trained")

case Monty.Studio.Memory.load_with_targets(name, release, 0) do
  {:ok, %{memory: memory, targets: targets}} ->
    graphs =
      memory
      |> GraphMemory.get_memory_ids()
      |> Enum.sort()

    for graph_id <- graphs do
      nodes =
        memory
        |> GraphMemory.get_graph(graph_id, "patch")
        |> Monty.Frameworks.Models.ObjectModel.GraphObjectModel.positions()
        |> length()

      names = Map.get(targets, graph_id, [graph_id])
      IO.puts("#{graph_id}: #{nodes} nodes · #{inspect(names)}")
    end

    named = for {_graph, names} <- targets, into: MapSet.new(), do: Enum.join(names, "+")

    IO.puts(
      "\n#{length(graphs)} graphs over #{MapSet.size(named)} names · " <>
        "#{Enum.count(targets, fn {_graph, names} -> length(names) > 1 end)} graphs hold more than one object"
    )

  {:error, :not_found} ->
    IO.puts("#{name}/#{release} is not a library that exists here")
end
