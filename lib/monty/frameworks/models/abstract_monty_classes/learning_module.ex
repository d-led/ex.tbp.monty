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

  @doc "Tells the module whether this episode trains or evaluates."
  @callback set_experiment_mode(state, mode()) :: state

  @doc """
  Folds what the episode saw into long-term memory, at the end of an episode.

  Only a training episode writes anything; the module decides that from the mode
  it was given.
  """
  @callback update_ltm_from_stm(state) :: state

  @optional_callbacks propose_goals: 1, propose_region: 1, get_output: 1

  @doc """
  Defaults for the parts not every learning module has: no goals, no region,
  no output. `use` this behaviour and override what applies.
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

      defoverridable propose_goals: 1, propose_region: 1, get_output: 1
    end
  end
end
