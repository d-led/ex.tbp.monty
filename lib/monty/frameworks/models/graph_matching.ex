defmodule Monty.Frameworks.Models.GraphMatching do
  @moduledoc """
  Matching against a library of learned objects — the graph-matching family.

  Mirrors `tbp/monty/frameworks/models/graph_matching.py`. That Python file
  holds three things: the model that drives a whole monty run
  (`MontyForGraphMatching`), the learning module family (`GraphLM` and the
  evidence-matching LM that extends it), and the memory those LMs read from.

  Ported so far:

    * `Monty.Frameworks.Models.GraphMatching.GraphMemory` — **ported**: the
      library of object models, the feature rows matching compares against, and
      the learning that extends a graph observation by observation.

  Still planned: `MontyForGraphMatching` and `GraphLM`, which arrive with the
  run itself once the evidence-matching LM exists to drive them.
  """
end
