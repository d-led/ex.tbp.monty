# Where the main loops stand, function by function.
#
#   MIX_ENV=test mix run --no-start scripts/loop_map.exs [--source ../monty-orig]
#
# The module map pairs Monty's *classes* with this port's modules. This script
# pairs the functions inside the classes the loops are made of, because a loop is
# 1:1 with Monty's only if its steps are. A method with no counterpart on one
# side is one of two things:
#
#   * a rename this port should not have made — fix the port;
#   * a piece Monty has that this port has not reached yet — say so and stop.
#
# Monty's leading underscores are dropped and a predicate's trailing `?` too, so
# `_sample_count` pairs with `sample_count`. The dunders pair with the lifecycle
# functions this port uses: `__init__` is `new`, `__enter__` is `begin_step`,
# `__exit__` is `end_step`.
#
# Output, per loop class: how many methods and functions it has, then the names
# that are on one side only — with the nearest name on the other side, so a
# rename reads as a near miss instead of as two unrelated words.
#
# A Monty method with no counterpart is either a rename to undo or a decision,
# and the decision is a line in `@elsewhere` naming where its work is done here.
# This port's side is read the same way but from the other end: a `defp` is a step
# inside one of the functions above — that is what the keyword means — so it is
# counted, not asked about; a public function needs a reason, which is a line in
# `@port`. A public function whose name Monty has in some other file is reported
# as a hint rather than as a decision: this port keeps one module per class while
# Monty spreads a class's methods over its bases, so that is usually where it
# comes from, and usually not.

defmodule LoopMap do
  alias Monty.ModuleMap.Data

  # The files a step is made of: the experiment's loop, the model that drives the
  # modules, the learning module, and the updaters and displacer it calls.
  @loops [
    "frameworks/experiments/monty_experiment.py",
    "frameworks/models/monty_base.py",
    "frameworks/models/evidence_matching/model.py",
    "frameworks/models/evidence_matching/learning_module.py",
    "frameworks/models/evidence_matching/hypotheses_updater.py",
    "frameworks/models/evidence_matching/burst_sampling.py",
    "frameworks/models/evidence_matching/hypotheses_displacer.py"
  ]

  @lifecycle %{"__init__" => "new", "__enter__" => "begin_step", "__exit__" => "end_step"}

  # Monty methods this port deliberately puts somewhere other than the class the
  # method belongs to. Each one is a decision, not a gap: the module that owns
  # it here is named, so the report counts it as accounted for.
  @elsewhere %{
    "frameworks/models/evidence_matching/hypotheses_updater.py" => %{
      "update_evidence" => "the behaviour's callbacks",
      "reset" => "the behaviour's callbacks",
      "displace_hypotheses" => "the behaviour's callbacks"
    },
    "frameworks/models/evidence_matching/learning_module.py" => %{
      # `_add_votes_to_buffer_stats` holds `pass` and a commented-out body: Monty
      # decided the vote data would clutter the buffer, so there is nothing to
      # port and nothing to call.
      "add_votes_to_buffer_stats" => "nothing: Monty's is `pass`"
    },
    "frameworks/models/evidence_matching/model.py" => %{
      # The class's constructor forwards to its base class and does nothing else.
      # Here the model is a process started by `Monty.Runtime.Model`, and this
      # module is the evidence-matching half of what that process answers.
      "new" => "Monty.Runtime.Model.start_link/1"
    },
    "frameworks/experiments/monty_experiment.py" => %{
      # This port's experiment class is the epoch and the episode loop and
      # nothing else: `run_epochs/2` walks the epochs, `run_epoch/2` the objects
      # of one. Everything Monty keeps beside that loop — the setup, the world,
      # the model, the counters, the loggers, the saved state — is the studio's,
      # because a run here is a job, not an object that is entered and exited.
      #
      # What one step is — the interface stepping a world, the model stepping on
      # what came back — is the studio's too.
      "new" => "Monty.Studio.Setup and Monty.Studio.Run.start/2",
      "begin_step" => "the run's start, Monty.Studio.Run.start/2: nothing is entered",
      "end_step" => "the run's stop, Monty.Studio.Run.stop/1: nothing is exited",
      "run_step" => "Monty.Studio.Run.step",
      "recognition_complete" => "_recognition_complete/2 here",
      "setup_experiment" => "the run's start, Monty.Studio.Run.start/2",
      "init_env" => "Monty.Studio.Setup.world/4",
      "load_environment_interfaces" => "one interface per episode, opened by Monty.Studio.Run",
      "create_env_interface" => "Monty.Experiment.Environment.Interface.new/1",
      "init_counters" => "the run's record counts episodes; an episode's is Monty.Experiment.RecognitionContext",
      "get_epoch_state" => "absent: the record holds epoch and episode, Setup.epoch_plan/1 the plan",
      "create_monty" => "Monty.Studio.Setup.model_spec/3, started as Monty.Runtime.Model",
      "snapshot_monty" => "absent: no recreation mode; Monty.Studio.Run.memories/1 carries memory between episodes",
      "restore_monty" => "absent: the same, an episode starts by resetting the model's short-term memory",
      "check_if_any_lms_updated" => "Monty.Runtime.Step: a step says what it processed",
      "fixme_generate_live_plot_frame" => "Monty.Studio.RunStream.publish/3 draws the frame",
      "pre_epoch" => "absent: the phase's mode and objects are chosen once, by Monty.Studio.Setup",
      "post_epoch" => "absent: the memory is kept once per run, Monty.Studio.Learned.keep/5; nothing is saved per epoch",
      "run" => "the phases are the config's plan, walked by Monty.Studio.Jobs.Run",
      "train" => "the plan's train phase, Monty.Studio.Jobs.Run",
      "evaluate" => "the plan's eval phase, Monty.Studio.Jobs.Run",
      "state_dict" => "absent at the experiment's level: a module's own state is Monty.Studio.Run.state/1",
      "save_state_dir" => "Monty.Studio.Learned.keep/5",
      "load_state_dir" => "Monty.Studio.Setup.memories/1",
      "close" => "Monty.Studio.Run.stop/1",
      "reset_episode_rng" => "Monty.Frameworks.Experiments.Seed.episode_seed/3",
      "logger_args" => "Monty.Studio.Run.logger_args/1",
      "init_loggers" => "Monty.Studio.Artifacts.start/1 makes the run's directory and log",
      "init_monty_data_loggers" => "Monty.Studio.Logging.open/1"
    }
  }

  # Public functions this port has and Monty has nowhere. Each one is a
  # consequence of a design the two do not share: Monty's modules are objects
  # that are mutated, so setting a target or a terminal state is an attribute
  # write there and a returned value here; its model is an object the experiment
  # holds, so asking it anything is a method call there and a process call here.
  @port %{
    # Monty's `train`/`evaluate` each loop their epochs calling `run_epoch`;
    # here the epoch loop is one function because the phase plan is the studio's.
    "run_epochs" => "the epoch loop inside Monty's train/evaluate, split out",
    # `EvidenceGraphLM` brackets a matching step with these so a burst can count
    # down; Monty has no such pair.
    "begin_step" => "the start of one matching step, which Monty does not bracket",
    "end_step" => "the end of one matching step, for the same reason",
    "message" => "Elixir's Exception protocol, which an exception struct answers",
    "graph_memory" => "reads the memory, which Monty holds as an attribute",
    "num_hypotheses" => "counts a graph's hypotheses, a list length in Monty",
    "conclusion" => "reads the terminal state, an attribute in Monty",
    "observation_processed" => "reads whether the last observation was processed, an attribute in Monty",
    "set_terminal_state" => "writes the terminal state, an attribute assignment in Monty",
    "clear_conclusion" => "clears the episode's answer, an attribute assignment in Monty",
    "clear_buffers" => "drops the buffer, which Monty resets in place",
    "displace_all" => "hands `displace_hypotheses` the buffer's last location",
    "set_target" => "sets the stepwise target, attribute assignments in Monty",
    "set_primary_target" => "names the episode's object, an attribute assignment in Monty",
    "set_stepwise_target" => "sets one step's target, which Monty writes through `_set_stepwise_targets`",
    # The model is a process here (`Monty.Runtime.Model`); these are what a
    # caller can ask of a running one.
    "child_spec" => "the model is a process here, so it has a child spec",
    "status" => "asks a running model how it is doing",
    "statistics" => "asks a running model for the statistics it collected",
    "stop" => "stops a running model",
    "supervise" => "tells a running model its supervised answer, a supervised run's call",
    "time_out" => "tells a running model the step budget ran out",
    # Names Monty has too, on a class that is not this one's: a coincidence, said
    # out loud so the hint below is not read as a pairing.
    "from_config" => "builds a module from a config map, which Monty's Hydra does",
    "set_individual_ts" => "writes one module's terminal state, an attribute in Monty",
    "state_dict" => "one module's own memento; Monty snapshots the model and the experiment",
    "state" => "reads a running model's state; Monty's `state` is an environment's",
    "step" => "one step of a running model; Monty's `step` is the attention system's"
  }

  def run(source) do
    IO.puts("monty: #{source}")
    IO.puts("module map read from: #{inspect(Data.sources(), limit: :infinity)}\n")

    defs = monty_defs(source)

    for entry <- Data.entries(), entry.python in @loops do
      for class <- entry.classes, class.status == :implemented, class[:file] do
        report(
          entry.python,
          class.python,
          class.elixir,
          methods(source, entry.python, class.python),
          functions(class.file),
          defs
        )
      end
    end

    pairless =
      for file <- @loops,
          not Enum.any?(Data.entries(), fn entry ->
            entry.python == file and Enum.any?(entry.classes, &(&1.status == :implemented))
          end),
          do: file

    if pairless != [] do
      IO.puts("not paired in the map, so not checked here:")

      Enum.each(pairless, fn file ->
        exists? = File.exists?(Path.join(source, "src/tbp/monty/" <> file))
        IO.puts("  #{file}#{if exists?, do: "", else: " (not in this checkout)"}")
      end)
    end
  end

  defp report(python_file, python_class, elixir_module, python, functions, defs) do
    elixir = Enum.map(functions, fn {name, _scope} -> name end)
    {paired, python_only} = pair(python, elixir)
    paired_names = Enum.map(paired, fn {_python, name} -> name end)

    {public_only, private_only} =
      for({name, scope} <- functions, name not in paired_names, do: {name, scope})
      |> Enum.split_with(fn {_name, scope} -> scope == :public end)

    IO.puts("#{python_file}::#{python_class} -> #{elixir_module}")

    IO.puts(
      "  #{length(python)} methods, #{length(elixir)} functions, " <>
        "#{length(paired)} paired by name"
    )

    for {name, nearest} <- python_only do
      case Map.get(@elsewhere, python_file, %{}) |> Map.get(name) do
        nil -> IO.puts("  monty only: #{name} (nearest: #{nearest})")
        elsewhere -> IO.puts("  elsewhere:  #{name} -> #{elsewhere}")
      end
    end

    for {name, :public} <- public_only do
      monty_file = Map.get(defs, "_" <> name) || Map.get(defs, name)

      cond do
        reason = Map.get(@port, name) ->
          IO.puts("  explained:  #{name} -> #{reason}")

        monty_file ->
          IO.puts("  same name:  #{name} (Monty has a method of that name in #{monty_file})")

        true ->
          IO.puts("  port only:  #{name} (no Monty method of that name)")
      end
    end

    # A `defp` is a step inside one of the functions above — that is what the
    # keyword means — so it is not a decision, only a count.
    if private_only != [] do
      IO.puts(
        "  #{length(private_only)} private helpers, each a step inside a method on this list"
      )
    end

    unaccounted =
      Enum.count(python_only, fn {name, _nearest} ->
        not Map.has_key?(Map.get(@elsewhere, python_file, %{}), name)
      end)

    if python_only != [] do
      IO.puts("  #{unaccounted} of #{length(python_only)} need a decision, one per method.")
    end

    undecided =
      Enum.reject(public_only, fn {name, _scope} ->
        Map.get(@port, name) || Map.get(defs, "_" <> name) || Map.get(defs, name)
      end)

    if public_only != [] do
      IO.puts(
        "  #{length(undecided)} of #{length(public_only)} public functions have no reason here " <>
          "and no Monty name."
      )
    end

    IO.puts("")
  end

  # Pairs both sides, and names the nearest Elixir function for a Monty method
  # that has no counterpart, so a rename is visible as a near miss.
  defp pair(python, elixir) do
    Enum.reduce(python, {[], []}, fn name, {paired, missing} ->
      case nearest(name, elixir) do
        {:exact, counterpart} -> {paired ++ [{name, counterpart}], missing}
        {:near, counterpart} -> {paired, missing ++ [{name, counterpart}]}
        :none -> {paired, missing ++ [{name, "—"}]}
      end
    end)
  end

  defp nearest(name, elixir) do
    case Enum.find(elixir, &(&1 == name)) do
      nil ->
        case Enum.map(elixir, &{&1, String.jaro_distance(name, &1)}) do
          [] ->
            :none

          scored ->
            {closest, similarity} = Enum.max_by(scored, &elem(&1, 1))
            if similarity > 0.75, do: {:near, closest}, else: :none
        end

      counterpart ->
        {:exact, counterpart}
    end
  end

  # Similarity is `String.jaro_distance/2`, which is a hint for a human — it
  # names the function a rename most probably became — and not a decision.

  # Monty's methods of one class: `    def name(` at that indent, from the class
  # line to the next one.
  defp methods(source, python_file, class) do
    path = Path.join(source, "src/tbp/monty/" <> python_file)

    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> methods_of(class)
      {:error, _reason} -> []
    end
  end

  defp methods_of(lines, class) do
    lines
    |> Enum.drop_while(&(not Regex.match?(~r/^class #{Regex.escape(class)}\b/, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not Regex.match?(~r/^class /, &1)))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^    def ([a-zA-Z_0-9]+)\(/, line) do
        [_, name] -> [name |> then(&Map.get(@lifecycle, &1, &1)) |> String.trim_leading("_")]
        nil -> []
      end
    end)
    |> Enum.uniq()
  end

  # This port's functions in one file, without the keyword and without arities: a
  # loop pairs by name, and an arity difference is a different question. A
  # behaviour's callbacks are functions of the class it stands for, so they
  # count too, as public ones. Capitals are allowed after the first letter,
  # because Monty has names like `init_EvidenceGraphLM` and the port keeps them.
  defp functions(file) do
    case File.read(file) do
      {:ok, text} ->
        ~r/^  (defp|def|@callback) ([a-zA-Z_0-9]+[?]?)/m
        |> Regex.scan(text)
        |> Enum.map(fn [_, keyword, name] ->
          {name |> String.trim_leading("_") |> String.trim_trailing("?"), scope(keyword)}
        end)
        |> Enum.group_by(fn {name, _scope} -> name end, fn {_name, scope} -> scope end)
        |> Enum.map(fn {name, scopes} -> {name, most_visible(scopes)} end)

      {:error, _reason} ->
        []
    end
  end

  defp scope("defp"), do: :private
  defp scope(_def), do: :public

  # One name can be defined at several arities; a name reachable from outside is a
  # public one.
  defp most_visible(scopes), do: if(:public in scopes, do: :public, else: :private)

  # Every method Monty's tree defines, name to the file that defines it. A port
  # module is one class, while Monty spreads a class's methods over its bases, so
  # a public function here may be a method Monty writes in another file.
  defp monty_defs(source) do
    source
    |> Path.join("src/tbp/monty/**/*.py")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn path, acc ->
      file = Path.relative_to(path, Path.join(source, "src/tbp/monty"))

      case File.read(path) do
        {:ok, text} ->
          ~r/^    def ([a-zA-Z_0-9]+)\(/m
          |> Regex.scan(text)
          |> Enum.reduce(acc, fn [_, name], inner -> Map.put_new(inner, name, file) end)

        {:error, _reason} ->
          acc
      end
    end)
  end
end

{options, _argv} = OptionParser.parse!(System.argv(), strict: [source: :string])
source = Keyword.get(options, :source) || System.get_env("MONTY_ROOT", "../monty-orig")

LoopMap.run(Path.expand(source))
