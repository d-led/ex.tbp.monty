defmodule Monty.Frameworks.Models.AbstractMontyClasses.LearningModule do
  @moduledoc """
  Behaviour for a learning module, mirroring
  `tbp/monty/frameworks/models/abstract_monty_classes.py::LearningModule`.

  Pure callbacks again: percepts and context in, next state out. The process
  (`Monty.Runtime.LearningModuleServer`) holds the state and nothing else, so
  the step semantics Monty defines — which inputs arrive, in which order, and
  what voting exchanges — live in `Monty.Runtime.Step` where they can be read
  and tested in one place.

  `matching_step/3` updates evidence and hypotheses; `exploratory_step/3`
  accumulates for later training. `send_out_vote/1` is called for every module
  before any module receives votes, which is what makes a vote round a round.
  """

  alias Monty.Cmp.{AttentionRegion, Goal, Message}

  @type state :: term()
  @type percepts :: [Message.t()]
  @type ctx :: Monty.Context.t()
  @type vote :: term()

  @doc "A step in which recognised objects are being matched against memory."
  @callback matching_step(percepts(), ctx(), state) :: {:ok, state}

  @doc "A step in which the module explores without matching."
  @callback exploratory_step(percepts(), ctx(), state) :: {:ok, state}

  @doc "What this module believes, for other modules to weigh."
  @callback send_out_vote(state) :: {vote(), state}

  @doc """
  Votes gathered from the modules wired to this one.

  What a vote *is* differs by family: the displacement modules exchange sets of
  objects they have excluded, the evidence modules a map of object id to the
  hypotheses worth voting for. The coordinator passes on whatever the senders'
  `send_out_vote/1` produced, and this callback decides how to weigh it.
  """
  @callback receive_votes(vote(), state) :: {:ok, state}

  @doc """
  Monty's `update_stats_after_vote`: what a vote round left this module
  believing.

  Asked after every round, for every module, whether or not it heard anything.
  Monty uses it to settle the module's own conclusion: nothing possible is
  `:no_match`, and a module that was `:no_match` is let back when other modules'
  votes have given it possibilities again — the terminal check never clears
  `:no_match`, so without this a module that lost its hypotheses once could
  never recover in the same episode.
  """
  @callback update_stats_after_vote(state) :: state

  @doc "A goal this module wants pursued (usually a hypothesis test)."
  @callback propose_goals(state) :: {[Goal.t()], state}

  @doc "The region this module wants attended to."
  @callback propose_region(state) :: {AttentionRegion.t(), state}

  @doc """
  What this module tells modules below it in the hierarchy, or `nil`.

  Read at the start of a step and delivered only if the receiver also saw a
  sensor percept that step — Monty's rule, and the reason a silent sensor
  stops a hierarchy from talking to itself.
  """
  @callback get_output(state) :: {Message.t() | nil, state}

  @doc "Clears short-term memory before a new episode."
  @callback reset_stm(state) :: state

  @doc """
  Drops what the module accumulated, and nothing it learned.

  Monty's `MontyForNoResetEvidenceGraphMatching._reset_modules_buffers` reaches
  into every module's buffer (`lm.buffer.reset()`) rather than resetting the
  module, because resetting would also throw away the hypotheses: a run without
  episode boundaries keeps what it believes across an object change and only
  frees the observations it will not read again. A module's state is opaque to
  the coordinator here, so that reach-in is a callback.

  The default is a module with no buffer — nothing to drop.
  """
  @callback clear_buffers(state) :: state

  # -- what the model asks between steps ------------------------------------
  #
  # Monty's model reaches into a module to ask whether it processed this step's
  # observation, whether it has concluded, and to tell it which mode the
  # experiment is in. A ported module's state is opaque to the coordinator, so
  # each question is a callback rather than an attribute read.

  @typedoc """
  What a module has concluded, or `nil` while it is still deciding.

  `:no_match` means nothing in memory explains what it saw; `:time_out` that
  the episode ended before it made up its mind; `:pose_time_out` that it chose
  an object but never settled on a pose.
  """
  @type terminal_state :: :match | :no_match | :time_out | :pose_time_out | nil

  @typedoc "Monty's `ExperimentMode`: training writes memory, evaluation does not."
  @type mode :: :train | :eval | nil

  @doc """
  Records whether this step's observation reached the module.

  `false` for a step the module was not given (no percepts for it, or percepts
  with no features): such a step is not evidence, so it neither counts towards
  symmetry nor justifies a vote.
  """
  @callback add_lm_processing_to_buffer_stats(state, boolean()) :: state

  @doc "Whether the last observation buffered was one this module processed."
  @callback observation_processed?(state) :: boolean()

  @doc """
  What the module has concluded so far, without asking it to reconsider.

  Monty's `lm.terminal_state` field. A module writes it from its own step as
  soon as it can conclude anything at all — `EvidenceGraphLM.matching_step`
  concludes `:no_match` the moment nothing is possible — and the model reads it
  to decide the step (`MontyForGraphMatching.check_terminal_conditions`).
  Deciding what to conclude is `update_terminal_condition/1`, which Monty asks
  for only once an episode is past its minimum number of steps.
  """
  @callback conclusion(state) :: terminal_state()

  @doc """
  Checks the module's own terminal condition and reports what it concluded.

  Called once per step in which the module processed an observation, so a
  module that counts evidence of symmetry sees every step in which it could
  have grown.
  """
  @callback update_terminal_condition(state) :: {state, terminal_state()}

  @doc """
  Sets the module's conclusion without asking it to reconsider.

  The model uses this to time out the modules that have not concluded once the
  system decision is made: they take part in the episode's statistics but claim
  nothing.
  """
  @callback set_terminal_state(state, terminal_state()) :: state

  @doc """
  Forgets what the module concluded, keeping everything it believes.

  Monty's `NoResetEvidenceGraphMatching._reset_terminal_states` calls
  `lm.set_individual_ts(None)` on every module at an object boundary: the
  episode's answer is over, the hypothesis space is not. The default is the
  narrowest thing that is true of every module — a module with no detected
  object to forget has only its terminal state to clear.
  """
  @callback clear_conclusion(state) :: state

  @doc """
  Names the object this episode is about, and leaves the module's history alone.

  Monty's `MontyForNoResetEvidenceGraphMatching.fixme_set_ground_truth` writes
  `lm.primary_target` and `lm.primary_target_rotation_quat` directly after the
  first episode, instead of the `fixme_reset_ground_truth` an ordinary episode
  calls — which would empty `stepwise_targets_list`, the record of what the
  sensor was on, step by step, across every object of the run.
  """
  @callback set_primary_target(state, map() | nil) :: state

  @doc "Tells the module whether this episode trains or evaluates."
  @callback set_experiment_mode(state, mode()) :: state

  @doc """
  The long-term memory this module holds, or `:none` for a module that keeps none.

  A run hands the memory of a training episode to the next one, and it is the
  module that holds it — `GraphLM.graph_memory`, which Monty reads straight off
  the attribute. A module's state is opaque here, so the module answers.
  """
  @callback graph_memory(state) :: Monty.Frameworks.Models.GraphMatching.GraphMemory.t() | :none

  @doc """
  Folds what the episode saw into long-term memory, at the end of an episode.

  Only a training episode writes anything; the module decides that from the mode
  it was given.
  """
  @callback update_ltm_from_stm(state) :: state

  @doc """
  Names the object this episode is about, and the pose it was placed with.

  Monty's `fixme_reset_ground_truth`: the target is what makes a performance
  measurable — "correct" means "recognised the object it was asked about" — so a
  module that is never told one cannot report a performance at all. `nil` leaves
  whatever it knew alone.
  """
  @callback set_target(state, map() | nil) :: state

  @doc """
  Records which object the module's sensor is on this step.

  Monty's `_set_stepwise_targets`: the model, not the module, reads the label
  off the percept's semantic id, and hands it here. It is logging information —
  the stepwise performance asks "was the object under the patch one the module
  was considering", which an episode reports and nothing matches on.
  """
  @callback set_stepwise_target(state, String.t()) :: state

  @doc """
  Records which objects the graph a training episode built came from.

  Monty's `fixme_update_ground_truth`, called after the episode's long-term
  memory is written. It is a record of the run's supervision, not something the
  model worked out, and a later evaluation is scored against it.
  """
  @callback fixme_update_ground_truth(state) :: state

  @optional_callbacks propose_goals: 1, propose_region: 1, get_output: 1

  @doc """
  Defaults for the parts not every learning module has: no goals, no region,
  no output, and no bookkeeping of its own after a vote.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def propose_goals(state), do: {[], state}

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def propose_region(state), do: {Monty.Cmp.AttentionRegion.empty(), state}

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def get_output(state), do: {nil, state}

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def update_stats_after_vote(state), do: state

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def clear_buffers(state), do: state

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def clear_conclusion(state), do: set_terminal_state(state, nil)

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def set_primary_target(state, primary_target), do: set_target(state, primary_target)

      @impl Monty.Frameworks.Models.AbstractMontyClasses.LearningModule
      def graph_memory(_state), do: :none

      defoverridable propose_goals: 1,
                     propose_region: 1,
                     get_output: 1,
                     update_stats_after_vote: 1,
                     clear_buffers: 1,
                     clear_conclusion: 1,
                     set_primary_target: 2,
                     graph_memory: 1
    end
  end
end
