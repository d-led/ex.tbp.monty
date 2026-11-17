defmodule Monty.Frameworks.Models.AbstractMontyClasses.SensorModule do
  @moduledoc """
  Behaviour for a sensor module, mirroring
  `tbp/monty/frameworks/models/abstract_monty_classes.py::SensorModule`.

  The callbacks are pure: they take the module's state and return the next
  state alongside their result. `Monty.Runtime.SensorModuleServer` is the thin
  process that holds that state; a module can be tested without a process at
  all.

  `update_state/2` is called before `step/3` on every step, because a sensor
  module needs to know where the sensor is before it can say what it observes.
  """

  alias Monty.Cmp.{AttentionRegion, Goal, Message}

  @typedoc "Whatever a module keeps between steps; opaque to the runtime."
  @type state :: term()
  @type agent_state :: map()
  @type observation :: map()

  @doc "Records the sensor's pose for the step about to run."
  @callback update_state(agent_state(), state) :: state

  @doc """
  Turns one raw observation into a percept, or `nil` when the sensor has
  nothing to say this step.

  The context is the run's — its step, its mode, and through
  `Monty.Context.rng_for/2` the random stream this sensor draws from. Monty
  passes one for the same reason (`CameraSM.step(ctx, ...)`): a sensor that adds
  noise needs to know which run and which step it is adding it to.
  """
  @callback step(observation(), boolean(), Monty.Context.t(), state) ::
              {Message.t() | nil, state}

  @doc "Clears short-term state for a new episode."
  @callback reset(state) :: state

  @doc """
  Drops the observations this sensor kept, and nothing it has learnt.

  Monty's `NoResetEvidenceGraphMatching._reset_modules_buffers` sets
  `sm.processed_obs = []` at an object boundary: the observations will not be
  read again, but the delta filter's memory decides what counts as a change and
  has to survive, or the first patch on the new object is a sight the sensor has
  never had. `reset/1` is the whole-episode version and is not the same thing.

  The default is a sensor that keeps nothing.
  """
  @callback clear_buffers(state) :: state

  @doc "Goals this sensor proposes (a salience module proposes; a camera does not)."
  @callback propose_goals(state) :: {[Goal.t()], state}

  @doc "The region this sensor wants attended to."
  @callback propose_region(state) :: {AttentionRegion.t(), state}

  @doc """
  Whether one step of this module draws from the episode's random stream.

  **This port's addition.** Monty's `SensorModule` has no such callback: what a
  sensor draws is invisible to it, because Python steps the sensors one after
  another anyway. `draws_from_stream?/1` exists here because stepping them at
  once is only safe when nobody draws — it is what makes
  `Step.step_sensor_modules/4` allowed to be concurrent, and it is *this port's*
  answer to a question Monty never has to ask
  (`docs/monty-differences.md` §2.28).

  The step coordinator asks this once, when the model is built, because it
  decides how the sensors are stepped: `Step.step_sensor_modules/4` can ask
  every sensor at once only when none of them draws. A sensor that draws pins
  the phase to the order it is stepped in — an episode has one stream and the
  draws are taken in that order (`Monty.Random.Stream`, `docs/monty-differences.md`
  §2.1) — so a module that answers `true` here keeps Monty's serial round and
  its numbers, and the ones that answer `false` are what a multi-sensor config
  gets concurrency from.

  The default is `false`: a sensor with no noise and no dither reads the
  observation and nothing else.
  """
  @callback draws_from_stream?(state) :: boolean()

  @optional_callbacks propose_goals: 1, propose_region: 1, draws_from_stream?: 1

  @doc """
  Defaults matching Monty's base `SensorModule`: a plain sensor proposes no
  goals and attends to nothing.

  A module `use`s this behaviour and overrides what it needs, which is how the
  Python base class reads too — and why a module that implements
  `propose_goals/1` does not have to fight a catch-all default clause.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Monty.Frameworks.Models.AbstractMontyClasses.SensorModule

      @impl Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
      def propose_goals(state), do: {[], state}

      @impl Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
      def propose_region(state), do: {Monty.Cmp.AttentionRegion.empty(), state}

      @impl Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
      def clear_buffers(state), do: state

      @impl Monty.Frameworks.Models.AbstractMontyClasses.SensorModule
      # This port's addition, not Monty's: a sensor says nothing about drawing
      # because Python steps it serially. `false` is the honest default for the
      # sensors this tree builds — no noise, no dither — and a sensor that draws
      # overrides it (§2.28).
      def draws_from_stream?(_state), do: false

      defoverridable propose_goals: 1, propose_region: 1, clear_buffers: 1, draws_from_stream?: 1
    end
  end
end
