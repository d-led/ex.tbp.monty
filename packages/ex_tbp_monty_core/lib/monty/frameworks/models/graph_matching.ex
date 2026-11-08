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
    * `Monty.Frameworks.Models.GraphMatching.GraphLM` — **ported**: the learning
      module this family is built on.
    * `Monty.Frameworks.Models.GraphMatching.MontyForGraphMatching` — **ported**:
      the vote round, which for this family is the union of the objects each
      module ruled out. The runtime does the rest of that class's job
      (`Monty.Runtime.Step`).
  """
end
