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
        disabled: [{Credo.Check.Design.AliasUsage, []}],
        extra: [
          # Rendering and sync code has a few deliberately explicit branches;
          # these thresholds keep the checks useful instead of stylistic.
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          # An evidence learning module is one column of Monty's cortical
          # column: the settings an experiment tunes and the short-term memory
          # it accumulates. Monty keeps both on the class, and splitting them
          # here would scatter the settings an experiment sets.
          {Credo.Check.Warning.StructFieldAmount, [max_fields: 35]}
        ]
      }
    }
  ]
}
