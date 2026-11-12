defmodule Monty.Studio.Run do
  @moduledoc """
  A run of the experiment you just looked at.

  The setup decides the topology; this starts it as supervised processes and
  steps the clock, one timestep per call. It is deliberately not a GenServer:
  the caller owns the clock (a page, a test, an Oban job), and a run is a value
  you pass around rather than a process you have to ask.

  What comes back from `step/2` is the coordinator's report for one timestep —
  percepts, learning-module inputs, votes, goals, actions — and what a page
  shows while the run is happening. `Monty.Studio.Summary` turns the collected
  reports into what a page shows after it.
  """

  alias Monty.Experiment.Environment.Interface
  alias Monty.Experiment.RecognitionStrategy
  alias Monty.Experiment.RecognitionStrategy.{RecognitionCounter, RecognitionResult}
  alias Monty.Frameworks.Experiments.Seed
  alias Monty.Runtime.{LearningModuleServer, Positioning, Registry}
  alias Monty.Studio.{Belief, Setup}

  # How many steps an episode may take when the caller names no number. Not a
  # budget a run should ever reach: it is the ceiling the experiment configs give
  # an evaluation episode (`max_eval_steps: 500`), so a run that is left to itself
  # gets as long as the experiment would have given it. Anything smaller cuts
  # episodes Monty would have let conclude — a recognition here takes about
  # twenty matching steps, and a twelve-step page stopped them all.
  @default_steps 500

  @enforce_keys [:model, :model_id, :setup, :interface, :episode_seed]
  defstruct [
    :model,
    :model_id,
    :setup,
    :interface,
    :episode_seed,
    :steps,
    step: 0,
    pending_actions: [],
    positioning: nil,
    policy: nil,
    counter: nil,
    first_seen: %{},
    started_in: []
  ]

  @type t :: %__MODULE__{
          model: module(),
          model_id: String.t(),
          setup: Setup.t(),
          interface: Interface.t(),
          episode_seed: non_neg_integer(),
          steps: pos_integer(),
          step: non_neg_integer(),
          pending_actions: [Monty.Frameworks.Actions.Action.t()],
          positioning: Monty.Runtime.Positioning.outcome() | nil,
          policy: Monty.Experiment.RecognitionStrategy.t() | nil,
          counter: Monty.Experiment.RecognitionStrategy.RecognitionCounter.t() | nil,
          first_seen: %{optional(String.t()) => [number()]},
          # What starting this episode cost, part by part, in microseconds.
          started_in: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Starts a model for an experiment.

  Options: `:steps` (how many timesteps this run is for, used for the
  controller's progress), `:model_id`, `:episode` (which episode of the epoch it
  is, counted from zero), `:epoch` (which pass over the objects this episode
  belongs to, which is what a sampler walking one pose per epoch reads), `:mode`
  (`:eval` or `:train`, default `:eval`),
  `:has_detailed_logger` (whether this run's logging wants the whole hypothesis
  space per step), and `:memory` — the memory each learning module starts from,
  by module id, defaulting to the pretrained one (`Setup.memories/1`). A run is
  one episode, so `:memory` and `memories/1` are what let a training phase keep
  what it learned between episodes.

  The episode number is not bookkeeping: a run's random draws come from the
  seed its episode derives from the experiment's, so the same experiment and a
  different episode number are different draws — which is exactly what makes the
  second episode of an epoch a different object seen from a different angle.
  """
  @spec start(Setup.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%Setup{} = setup, opts \\ []) do
    # No run is built from stand-ins: a setup whose classes this port has not
    # written is refused here too, not only on the page that offered it.
    if Setup.valid?(setup) do
      do_start(setup, opts)
    else
      {:error, {:not_runnable, Enum.map(Setup.findings(setup, :error), & &1.message)}}
    end
  end

  defp do_start(%Setup{} = setup, opts) do
    model_id =
      Keyword.get_lazy(opts, :model_id, fn -> "studio-#{System.unique_integer([:positive])}" end)

    episode = Keyword.get(opts, :episode, 0)
    mode = Keyword.get(opts, :mode, :eval)

    # A model can outlive an episode. Monty's experiment is one model per run whose
    # short-term state is cleared per episode — `Monty.Runtime.Episode.run/3` is
    # that loop without the experiment around it — and building one per episode paid
    # for the memory's graphs every time: 895 ms of a 1.7 s episode, measured on the
    # ten-object config. A model this run already has is reset and stepped again;
    # whoever started it stops it when the phase ends (`Run.stop_model/1`).
    held? = Monty.Runtime.Registry.lookup({:model, model_id}) != []

    {prepared, {spec, model, factories, policy}} =
      :timer.tc(fn ->
        spec =
          if held?,
            do: nil,
            else:
              Setup.model_spec(setup, model_id,
                has_detailed_logger: Keyword.get(opts, :has_detailed_logger, false),
                memory: Keyword.get_lazy(opts, :memory, fn -> Setup.memories(setup) end)
              )

        {:ok, factories} = Setup.positioning_procedures(setup)
        {:ok, policy} = Setup.recognition_strategy(setup)
        {spec, Setup.model_class(setup), factories, policy}
      end)

    with {:ok, interface, positioning, placed_in} <-
           position(setup, factories, episode, epoch: Keyword.get(opts, :epoch, 0), phase: mode) do
      {started_in, started} =
        :timer.tc(fn ->
          if held? do
            :ok = Monty.Runtime.Model.reset_episode(model_id)
            {:ok, :held}
          else
            DynamicSupervisor.start_child(ExTbpMonty.Core.ModelSupervisor, {model, spec})
          end
        end)

      case started do
        {:ok, _pid} ->
          # The mode is told to the model, not assumed by it. Monty's experiment
          # sets it on the model before an epoch steps, and the coordinator's own
          # ending rule has no branch for a model that was told nothing: an
          # episode that recognises its object neither stops nor switches to
          # exploring, and only the page's step budget ends it.
          :ok = model.set_experiment_mode(model_id, mode)

          {:ok,
           %__MODULE__{
             model: model,
             model_id: model_id,
             setup: setup,
             # What starting the episode cost, part by part: the memory and the
             # config it resolved, the scene, the positioning steps the world
             # took to put the agent in front of the object, and the model's own
             # process. A run's boundaries are half its wall clock and this is
             # the half nobody can see.
             started_in: [{"prepared", prepared}] ++ placed_in ++ [{"model", started_in}],
             episode_seed: Seed.episode_seed(seed(setup), mode, episode),
             # The world starts where an episode starts, not where the last one
             # left it: a run is an episode — and where that is, the positioning
             # procedures have just decided.
             interface: interface,
             positioning: positioning,
             policy: policy,
             counter: RecognitionCounter.new(mode),
             steps: Keyword.get(opts, :steps, @default_steps),
             # Where each object stood the first time the experiment showed it.
             # A later epoch may place it somewhere else, and a graph has to
             # stay where it was learned.
             first_seen: Keyword.get(opts, :first_seen, %{})
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Monty's `MontyObjectRecognitionExperiment.pre_episode`: the model is told what
  the episode is about.

  Both halves arrive from the same place. The world that chose the object also
  named the semantic ids in its scene, which is what lets a step say *which*
  object was under the patch rather than only that one was; Monty's own
  experiment passes both
  (`object_recognition_experiments.py`).
  """
  @spec set_ground_truth(t(), keyword()) :: :ok
  def set_ground_truth(
        %__MODULE__{model: model, model_id: model_id, interface: interface},
        opts \\ []
      ) do
    world = interface.env

    # The world's own names unless the caller says it has none: Monty's
    # pretraining passes the target alone, and then no step can name the object
    # under the patch, which is the truth for an experiment that does not
    # recognise anything.
    labels =
      Keyword.get_lazy(opts, :semantic_id_to_label, fn -> labels(world) end)

    target =
      if function_exported?(world.__struct__, :primary_target, 1),
        do: world.__struct__.primary_target(world)

    model.fixme_set_ground_truth(model_id, target, semantic_id_to_label: labels)

    :ok
  end

  # A world without semantics answers nothing, which is what an empty map says:
  # every step's stepwise target is then `no_label`, Monty's own word for a
  # sensor that cannot name what it is on.
  defp labels(world) do
    if function_exported?(world.__struct__, :semantic_id_to_label, 1),
      do: world.__struct__.semantic_id_to_label(world),
      else: %{}
  end

  @doc """
  Monty's `_pass_target_info_to_model`: the episode's answer, stated rather than
  matched.

  Only a supervised experiment asks for this, and it asks at the end of the
  episode — after every step has written its own statistics and before the
  memory is written (`next_memories/3`), which is the order Monty's
  `post_episode` has.

  The answer includes where the object *first* stood, so a later epoch that
  places it somewhere else still extends the graph it built the first time. That
  map travels with the run.

  Every config that supervises modules here names `DisplacementGraphLM`, which
  answers this; an evidence module has no supervised conclusion in this port
  yet, and a config that asked for one would fail loudly rather than learn
  nothing.
  """
  @spec supervise(t()) :: {:ok, t()}
  def supervise(%__MODULE__{setup: setup} = run) do
    target = target(run) || no_target!(run)
    object = Map.fetch!(target, "object_name")

    location_on_model =
      Map.get_lazy(run.first_seen, object, fn -> Map.fetch!(target, "position") end)

    :ok =
      run.model.supervise(
        run.model_id,
        target,
        location_on_model,
        Setup.supervised_ids(setup)
      )

    {:ok,
     %{run | first_seen: Map.put_new(run.first_seen, object, Map.fetch!(target, "position"))}}
  end

  @spec no_target!(t()) :: no_return()
  defp no_target!(run) do
    raise ArgumentError,
          "a supervised episode needs a world that says what it showed, and " <>
            "#{inspect(run.setup.name)} steps a world that does not"
  end

  # Monty's `pre_episode`: the world is reset, then looked at and stepped until
  # the agent is in front of the object, before the model sees anything. The
  # steps taken here are the environment's, not the episode's, so the run's step
  # counter starts at zero afterwards.
  #
  # The reset comes first because that is the order Monty's `Interface.pre_episode`
  # has, and because it is the only thing that starts an episode in a world that
  # lives in another process: `HabitatEnvironment.reset/1` is what runs Monty's own
  # `pre_episode` in the peer. Without it a run stepped a world that had never been
  # told an episode had begun.
  #
  # A world that positions the episode itself — Monty's own, behind the port — has
  # done the positioning inside that reset, with Monty's random stream; stepping
  # the procedures again would move an agent Monty had placed and make the episode
  # a different one.
  defp position(%Setup{} = setup, factories, episode, opts) do
    # The episode's own object: Monty's interface shows one object per episode and
    # walks the list, so the world a run builds is about *this* episode's target —
    # in the pose its phase's sampler gives this episode of this epoch.
    {scene, interface} =
      :timer.tc(fn ->
        world = Setup.world(setup, episode, opts)

        interface =
          Interface.new(
            env: world,
            # The next episode starts where Monty starts one: a new scene for a world
            # that is a value, and the peer's own reset for a world that is a process
            # — never a second peer.
            reset: fn -> world.__struct__.reset(world) end,
            transforms: Setup.built_transforms(setup),
            seed: seed(setup)
          )

        {_observations, _proprioceptive_state, interface} = Interface.pre_episode(interface)
        interface
      end)

    if Monty.Simulators.Environment.positions_itself?(interface.env) do
      {:ok, interface, %{steps: nil, success: true, procedures: [:world]}, [{"scene", scene}]}
    else
      observe = fn interface, actions -> Interface.step(interface, actions) end

      {positioning, placed} =
        :timer.tc(fn ->
          Positioning.prepare(
            factories,
            Setup.target_semantic_id(setup, episode),
            interface,
            observe,
            distractors: Setup.distractors(setup)
          )
        end)

      case placed do
        {:ok, positioned, outcome} ->
          {:ok, positioned, outcome, [{"scene", scene}, {"positioning", positioning}]}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  What the world rendered this step, before the experiment's transforms ran.

  `step/1` answers the transformed observations, because that is what the model is
  given. A page showing the object wants the picture the world drew — a transform
  that clips depth to the patch's reach turns a surface into a flat slab — so this
  asks the world directly, and answers `nil` for a world that cannot say.
  """
  @spec rendered_observations(t()) :: map() | nil
  def rendered_observations(%__MODULE__{interface: interface}) do
    world = interface.env

    if function_exported?(world.__struct__, :observation, 1),
      do: world.__struct__.observation(world)
  end

  @doc """
  What each learning module believes after the run's last step, keyed by module id.

  The coordinator's report says what the modules *were given*; this says what they
  made of it, which is the other half of a step and the half a chart draws.
  """
  @spec beliefs(t()) :: %{optional(atom() | String.t()) => Belief.t()}
  def beliefs(%__MODULE__{model_id: model_id, setup: setup}) do
    Belief.all(model_id, Enum.map(setup.learning_modules, & &1.id))
  end

  @doc """
  The coordinator's state, which is what a logger reads an episode out of.

  Monty hands its logger the *model*, and the logger asks it for the episode
  number, the mode, the modules and their terminal states. The coordinator's
  state is this port's model: the same four answers, in one value.
  """
  @spec state(t()) :: Monty.Runtime.Step.State.t()
  def state(%__MODULE__{model: model, model_id: model_id}), do: model.state(model_id)

  @doc """
  What this episode is about: the object the world says it put in front of the
  agent, or `nil` for a world that does not ask the question.

  Monty's `logger_args` records a target only for a `OneObjectPerEpisodeInterface`;
  a world here answers it by exporting `primary_target/1`, which is the same
  distinction made the same way the episode's target is told to the model.
  """
  @spec target(t()) :: map() | nil
  def target(%__MODULE__{interface: interface}) do
    world = interface.env

    if function_exported?(world.__struct__, :primary_target, 1),
      do: world.__struct__.primary_target(world)
  end

  @doc """
  Monty's `logger_args`: the counters a handler keys an episode by.

  They are counters of the *run so far*, which is why they are zero here: a studio
  run is one episode and this is the first, and Monty's experiment increments them
  after the logger has been given the episode — the episode being logged is the one
  that has not been counted yet.
  """
  @spec logger_args(t()) :: map()
  def logger_args(%__MODULE__{episode_seed: seed} = run) do
    args = %{
      "total_train_steps" => 0,
      "train_episodes" => 0,
      "train_epochs" => 0,
      "total_eval_steps" => 0,
      "eval_episodes" => 0,
      "eval_epochs" => 0,
      "episode_seed" => seed
    }

    case target(run) do
      nil -> args
      target -> Map.put(args, "target", target)
    end
  end

  @doc """
  Runs one timestep, returning the report and the advanced run.

  The world is stepped with the actions the model chose on the *previous* step,
  and the report's observations come from *this* one: Monty's `Interface.step/1`
  hands the environment the actions it was given last time, and the first step
  of an episode is taken where the sensors already are.

  A failing module surfaces as an exit from the coordinator rather than a
  returned error: a step either produced a report or the run itself is broken,
  and pretending otherwise here would only move the decision.
  """
  @spec step(t()) :: {:ok, map(), map(), t()}
  def step(%__MODULE__{model: model, model_id: model_id, step: step} = run) do
    {world_us, {observations, proprioceptive_state, interface}} =
      :timer.tc(fn -> Interface.step(run.interface, run.pending_actions) end)

    ctx = %{Monty.Context.new(run.episode_seed) | step: step}

    {:ok, actions, info} = model.step(model_id, observations, proprioceptive_state, ctx)

    # The world's own step is not the model's, and a run cannot be made faster by
    # reading one number as the other.
    info = Map.put(info, :world_us, world_us)

    # The observations come back with the report so a page can show what the
    # modules saw, not just what they did with it.
    run = %{
      run
      | step: step + 1,
        interface: interface,
        pending_actions: actions,
        counter:
          RecognitionCounter.count_step(
            run.counter,
            info.processed?,
            info.step_type == :exploratory
          )
    }

    # Monty's `_recognition_complete` asks the policy and does what it asks for
    # before the loop decides whether to go on — which is what makes a stopping
    # decision's time-out reach the model, rather than being asked for and then
    # never applied. The loop asks it (`MontyExperiment.run_episode_steps/2`),
    # so nothing about it belongs to the step.
    {:ok, info, observations, run}
  end

  @doc """
  What the experiment's recognition policy makes of the run so far.

  This is the question the experiment asks each step — `is_done` ends the run,
  `time_out_lms` and `start_exploring` are the two things it can ask for
  instead — and the answer is also what a run's summary can report.
  """
  @spec decision(t()) :: RecognitionResult.t()
  def decision(%__MODULE__{policy: nil}), do: %RecognitionResult{}

  def decision(%__MODULE__{policy: policy, counter: counter} = run) do
    RecognitionStrategy.call(policy, model_view(run), counter)
  end

  @doc """
  What each learning module holds in long-term memory now, by module id.

  A run is one episode and its processes stop at the end of it, so this is what
  has to be handed to the next run for a training phase to keep what it learned:
  `start/2`'s `:memory`.
  """
  @spec memories(t()) :: %{optional(atom() | String.t()) => term()}
  def memories(%__MODULE__{model_id: model_id, setup: setup}) do
    Map.new(setup.learning_modules, fn learning_module ->
      server = Registry.via({:learning_module, model_id, learning_module.id})
      {learning_module.id, LearningModuleServer.graph_memory(server)}
    end)
  end

  @doc """
  Folds this episode into long-term memory: Monty's `model.update_ltm()`.

  The experiment calls it at the end of an episode, after the episode has been
  logged — the write rewrites the mapping from graphs to targets, and an episode
  logged after it would look confused about the object it just recognised — and
  the module decides what it means: a training episode writes, an evaluation one
  does not (`EvidenceGraphLM.update_ltm_from_stm/1`).
  """
  @spec update_ltm(t()) :: :ok
  def update_ltm(%__MODULE__{model: model, model_id: model_id}), do: model.update_ltm(model_id)

  @doc """
  What the next episode starts from: `memories/1` after a training episode,
  the memory it was given after an evaluation one.

  A training episode hands on the graphs it built, because that is what
  learning means — the next episode of the phase, whether it trains or
  evaluates, matches against them. An evaluation episode writes nothing
  (`EvidenceGraphLM.update_ltm_from_stm/1`), so it hands on what it was given:
  reading the memory back copies tens of megabytes out of every module process
  (`LearningModuleServer.state/1`) for a value that cannot have changed.

  This is the one rule behind "an epoch continues where the last episode
  stopped", so it is written once and both runners — the queued one and
  `mix monty.run` — ask it rather than each keeping their own copy.
  """
  @spec next_memories(t(), %{optional(atom() | String.t()) => term()}, :train | :eval) :: %{
          optional(atom() | String.t()) => term()
        }
  def next_memories(%__MODULE__{} = run, _memories, :train) do
    :ok = update_ltm(run)
    memories(run)
  end

  def next_memories(%__MODULE__{}, memories, :eval), do: memories

  @doc """
  What the model concluded: each learning module's terminal state, if any.

  Read from the model rather than from the last step's report, because the
  ending an episode gets from a time-out happens after that report.
  """
  @spec conclusion(t()) :: %{optional(atom()) => term()}
  def conclusion(%__MODULE__{model: model, model_id: model_id}),
    do: model.state(model_id).terminal_states

  @doc """
  Whether the run is over: the experiment's policy, or this page's step budget.

  Monty's `_recognition_complete`: the policy is asked, and the two things it may
  ask for besides stopping are done here — so an episode that keeps exploring or
  times its modules out is told before the next step, which is where Monty tells
  it. The step budget is the page's addition: a run whose policy never concludes
  still has to yield.
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{step: step, steps: steps} = run) do
    decision = decision(run)
    apply_reactions(run, decision)
    step >= steps or decision.is_done
  end

  @doc "Stops the run's processes — the model and the world it steps; safe to call twice."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{model: model, model_id: model_id, interface: interface}) do
    model.stop(model_id)
    Monty.Simulators.Environment.stop(interface.env)
  end

  @doc """
  Stops the world an episode stepped, and leaves its model alone.

  A model outlives the episode it steps (`Run.start/2` reuses one that is already
  there), so an episode that ends is a world that is done, not a model that is.
  """
  @spec stop_world(t()) :: :ok
  def stop_world(%__MODULE__{interface: interface}),
    do: Monty.Simulators.Environment.stop(interface.env)

  @doc """
  Stops the model an episode stepped, whatever world it was in.

  Called by whoever started the model — the phase, in a run — and by an episode
  that learned something, because the next episode's memory is not this one's.
  """
  @spec stop_model(t()) :: :ok
  def stop_model(%__MODULE__{model: model, model_id: model_id}), do: model.stop(model_id)

  @doc "How many steps a run of this experiment takes by default."
  @spec default_steps() :: pos_integer()
  def default_steps, do: @default_steps

  defp seed(%Setup{seed: seed}) when is_integer(seed), do: seed
  defp seed(_setup), do: 0

  # Monty's `_recognition_complete`: the two things a policy can ask for besides
  # stopping.
  defp apply_reactions(%__MODULE__{model: model, model_id: model_id}, decision) do
    if decision.start_exploring, do: :ok = model.switch_to_exploratory_step(model_id)
    if decision.time_out_lms, do: :ok = model.time_out(model_id)
  end

  # The four things a policy may read off the model (`docs/monty-differences.md` §2.17).
  defp model_view(%__MODULE__{model: model, model_id: model_id}), do: model.status(model_id)
end
