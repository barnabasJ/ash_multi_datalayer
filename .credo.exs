# Project credo policy:
# - AliasUsage is disabled: Spark DSL sections and layer declarations
#   reference modules inline by design (`layer :l1, Ash.DataLayer.Ets`);
#   aliasing them hurts readability. Standard practice in Ash projects.
# - Nesting/complexity limits raised one notch: the read/write dispatch
#   decision trees legitimately branch on kill-switch/coverage/layer-shape.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Design.AliasUsage, []}
        ],
        extra: [
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]}
        ]
      }
    }
  ]
}
