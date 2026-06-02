%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "src/",
          "test/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/", ~r"/credo/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          #
          ## Custom Checks
          #
          {Still.Credo.NoDirectErrorRendering,
           [
             controller_paths: ["lib/still_web/controllers/"]
           ]},
          {Still.Credo.NoRepoInController,
           [
             repo_modules: [Still.Repo],
             controller_paths: ["lib/still_web/controllers/"]
           ]},
          {Still.Credo.NoResourcesInRouter,
           [
             included_files: ["lib/still_web/router.ex"]
           ]},
          {Still.Credo.NoSleepInTests, []},
          {Still.Credo.PublicFunctionArgumentPatterns,
           [
             ignored_files: [
               "lib/still/application.ex",
               ~r/test\/.+_test\.exs$/,
               "test/support/*.ex"
             ],
             # Function components take `assigns` whole and never head-match it.
             ignored_argument_names: [:assigns],
             ignore_arities: [
               # Phoenix LiveView callbacks
               {:mount, 3},
               {:render, 1},
               {:handle_event, 3},
               {:handle_info, 2},
               {:handle_params, 3},
               {:handle_async, 3},
               {:update, 2},
               {:on_mount, 4},
               {:terminate, 2},

               # Phoenix Controller / view callbacks
               {:render, 2},
               {:action, 2},
               {:call, 2},
               {:index, 2},
               {:show, 2},
               {:create, 2},
               {:delete, 2},
               {:new, 2},
               {:edit, 2}
             ]
           ]},
          {Still.Credo.PublicFunctionDocumentation,
           [
             ignored_files: [
               "test/support/**/*.ex",
               ~r/test\/.+_test\.exs$/,
               "credo/**/*.ex",
               "lib/still_web.ex",
               "lib/still/application.ex"
             ],
             ignore_functions: [
               :__struct__,
               :child_spec
             ],
             ignore_arities: [
               # GenServer callbacks
               {:init, 1},
               {:start_link, 1},
               {:handle_call, 3},
               {:handle_cast, 2},
               {:handle_info, 2},
               {:handle_continue, 2},
               {:terminate, 2},
               {:code_change, 3},

               # Supervisor callbacks
               {:init, 1},

               # Phoenix Controller callbacks
               {:action, 2},
               {:call, 2},
               {:create, 2},
               {:show, 2},
               {:delete, 2},
               {:render, 2},
               {:update, 2},
               {:index, 2},
               {:new, 2},
               {:edit, 2},

               # Ecto callbacks
               {:changeset, 2},

               # Phoenix Channel/Socket callbacks
               {:connect, 3},
               {:join, 3},
               {:id, 1},
               {:handle_in, 3}
             ]
           ]},

          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          #
          ## Design Checks
          #
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Design.TagTODO, [exit_status: 2]},

          #
          ## Readability Checks
          #
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, []},

          #
          ## Refactoring Opportunities
          #
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.StructFieldAmount, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []}
        ],
        disabled: []
      }
    }
  ]
}
