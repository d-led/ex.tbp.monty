%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "mix_tasks/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      color: true,
      checks: %{
        # `Design.AliasUsage` asks for aliases of every nested module; in this
        # codebase the fully qualified names are often clearer (and required in
        # templates), so it is noise rather than signal.
        #
        # `Consistency.ExceptionNames` guesses an exception-naming convention
        # from what is already there and then complains about the exceptions
        # that do not follow it. Here the names are Monty's — `NoGoalProvided`,
        # `GridTooSmallError`, `InvalidEvidenceThresholdConfig`,
        # `ParentLMNotProvided` — and Module.for-module means they cannot be
        # renamed to suit a heuristic.
        disabled: [
          {Credo.Check.Design.AliasUsage, []},
          {Credo.Check.Consistency.ExceptionNames, []}
        ],
        extra: [
          # Rendering and sync code has a few deliberately explicit branches;
          # these thresholds keep the checks useful instead of stylistic.
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          # An evidence learning module is one column of Monty's cortical
          # column: the settings an experiment tunes, the short-term memory it
          # accumulates, and the ground truth a training episode records
          # (`primary_target`, `graph_id_to_target` and their like, which Monty
          # keeps on `GraphLM` — the base class this port cannot inherit from).
          # Monty keeps all of it on the class, and splitting it here would
          # scatter the settings an experiment sets and put the fields the
          # ported logger reads somewhere Monty does not have them.
          {Credo.Check.Warning.StructFieldAmount, [max_fields: 40]}
        ]
      }
    }
  ]
}
