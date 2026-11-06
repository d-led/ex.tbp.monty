defmodule Monty.Frameworks.Experiments.MontyExperiment do
  @moduledoc """
  `tbp/monty/frameworks/experiments/monty_experiment.py::MontyExperiment`.

  Monty's base experiment owns two loops: the epoch, which runs one *episode per
  object* an experiment names, and the episode, which steps the model against the
  world until the experiment's recognition policy says the episode is over.

      def run_epoch(self):
          self.pre_epoch()
          for object_name in self.env_interface.object_names:
              self.run_episode()

      def run_episode(self):
          self.pre_episode()
          last_step = self.run_episode_steps()
          self.post_episode(last_step)

      def run_episode_steps(self):
          count = RecognitionCounter(mode=self.experiment_mode)
          while not self._recognition_complete(count):
              actions = self.run_step(ctx, count.step, actions)
              count.step += 1

  All four are here, in that order and with those names. What they are *given* is
  a map of callbacks rather than a Python object graph, because what one step is
  — the interface stepping the world with the last actions, the model stepping on
  what came back, the counter counting only the steps an LM actually saw — is
  `Monty.Studio.Run`, and what a finished episode leaves behind is the studio's
  record. The experiment owns the loops; the studio owns the clock, the records
  and the page.

  ## Why an epoch exists here at all

  A run used to be one episode of one object, because this port had no epoch
  loop. It has one now: `run_epoch/2` walks the config's object list, one episode
  each, and each episode ends the way Monty's does — the recognition policy said
  done, or the caller's step budget ran out. That is what makes the port's numbers
  comparable at all: the same ten objects, in the same order, ending the same way.

  ## Where it deliberately differs

  Monty's loop ends in one of two ways — the policy said done, or the loop ran out
  of steps — and anything else raises across the epoch. A studio run also has a
  caller who may ask it to stop, and a step that dies, and a page has to be able
  to say which of those happened rather than wait for ever. So both loops are
  given a `:stopped?` test, and a step that reported a failure ends the epoch with
  `{:crashed, step, reason}` instead of throwing.

  Monty's `run_episode` may also skip a training episode whose target is not
  visible (`skip_on_object_not_visible`); there is no training loop here, so a
  `pre_episode` that fails ends the epoch and names the object it was about.
  """

  @typedoc "How an episode or an epoch ended."
  @type outcome :: :finished | :stopped | {:crashed, non_neg_integer(), term()}

  @typedoc "One episode of an epoch, as the page and the record name it."
  @type episode_result :: %{
          object: String.t() | nil,
          episode: non_neg_integer(),
          outcome: outcome(),
          steps: non_neg_integer()
        }

  @typedoc """
  What the experiment needs of the thing it is driving.

    * `:objects` — the names the epoch visits, one episode each;
    * `:experiment` — the module whose `pre_episode/4` an episode begins with, so
      a config that names `MontyObjectRecognitionExperiment` runs *through* it.
      Defaults to this module;
    * `:pre_episode` — the interface's half: ask the world for an episode, position
      the agent, and answer the state that episode is stepped in;
    * `:step` — one step, answering the episode's report (`{:ok, info, state}`)
      or why it could not be taken (`{:error, reason}`);
    * `:finished?` — Monty's `_recognition_complete`: the experiment's recognition
      policy, asked before every step;
    * `:stopped?` — whether the caller has asked the run to stop;
    * `:post_episode` — Monty's `post_episode`: what the end of an episode owes,
      which is the studio's record and its counters.
  """
  @type callbacks(state, info) :: %{
          required(:objects) => [String.t()],
          required(:pre_episode) => (state,
                                     non_neg_integer(),
                                     String.t(),
                                     callbacks(state, info) ->
                                       {:ok, state} | {:error, term()}),
          required(:step) => (state -> {:ok, info, state} | {:error, term()}),
          required(:finished?) => (state -> boolean()),
          required(:stopped?) => (-> boolean()),
          required(:post_episode) => (state, outcome(), [info] -> state),
          optional(:epochs) => non_neg_integer(),
          optional(:episodes) => non_neg_integer() | :all,
          optional(:first_episode) => non_neg_integer(),
          optional(:experiment) => module(),
          optional(:ground_truth) => (state -> {:ok, state} | {:error, term()})
        }

  @doc """
  Monty's `evaluate()`: `epochs` epochs, each one episode per object.

  A rotation experiment is exactly this — the same object list walked again with
  a different draw, so `base_77obj_dist_agent`'s `${constants.rotations_3_count}`
  is three walks of seventy-seven objects, not one. The episode number is what
  carries the draw (`Monty.Frameworks.Experiments.Seed`), so it counts *across*
  epochs: episode 78 is the first object of the second rotation, not a repeat of
  episode 0.

  Answers the outcome, every episode of the run — oldest first — and the state
  the last one left behind.
  """
  @spec run_epochs(state, callbacks(state, info)) :: {outcome(), [episode_result()], state}
        when state: term(), info: term()
  def run_epochs(state, %{epochs: epochs} = callbacks) do
    experiment = Map.get(callbacks, :experiment, __MODULE__)
    per_epoch = length(callbacks.objects)

    run_epochs(
      max(epochs, 1),
      per_epoch,
      0,
      Map.get(callbacks, :episodes, :all),
      state,
      callbacks,
      experiment,
      []
    )
  end

  defp run_epochs(0, _per_epoch, _first, _budget, state, _callbacks, _experiment, episodes),
    do: {:finished, Enum.reverse(episodes), state}

  defp run_epochs(_epochs, _per_epoch, _first, 0, state, _callbacks, _experiment, episodes),
    do: {:finished, Enum.reverse(episodes), state}

  defp run_epochs(epochs, per_epoch, first, budget, state, callbacks, experiment, episodes) do
    if callbacks.stopped?.() do
      {:stopped, Enum.reverse(episodes), state}
    else
      {outcome, ran, state} =
        experiment.run_epoch(
          state,
          Map.merge(callbacks, %{
            first_episode: first,
            episodes: budget,
            epoch: div(first, per_epoch)
          })
        )

      episodes = Enum.reverse(ran, episodes)
      budget = spent(budget, length(ran))

      case {outcome, budget} do
        {:finished, 0} ->
          {:finished, Enum.reverse(episodes), state}

        {:finished, _more} ->
          run_epochs(
            epochs - 1,
            per_epoch,
            first + per_epoch,
            budget,
            state,
            callbacks,
            experiment,
            episodes
          )

        {other, _budget} ->
          {other, Enum.reverse(episodes), state}
      end
    end
  end

  defp spent(:all, _ran), do: :all
  defp spent(budget, ran), do: max(budget - ran, 0)

  @doc """
  Runs one episode per object, in the order the experiment names them.

  Answers the epoch's outcome, what each episode did — oldest first, because an
  epoch is read as a sequence — and the state the last episode left behind.
  """
  @spec run_epoch(state, callbacks(state, info)) :: {outcome(), [episode_result()], state}
        when state: term(), info: term()
  def run_epoch(state, %{objects: objects} = callbacks) do
    run_objects(
      Enum.take(objects, budget(Map.get(callbacks, :episodes, :all), objects)),
      Map.get(callbacks, :first_episode, 0),
      state,
      callbacks,
      []
    )
  end

  defp budget(:all, objects), do: length(objects)
  defp budget(count, _objects) when is_integer(count), do: max(count, 0)

  defp run_objects([], _index, state, _callbacks, episodes),
    do: {:finished, Enum.reverse(episodes), state}

  defp run_objects([object | rest], index, state, callbacks, episodes) do
    # A stop lands between episodes, as it lands between steps: the episode not
    # begun is an episode the run did not take.
    if callbacks.stopped?.() do
      {:stopped, Enum.reverse(episodes), state}
    else
      run_episode(state, object, index, callbacks, episodes, rest)
    end
  end

  defp run_episode(state, object, index, callbacks, episodes, rest) do
    # The class the config names decides how an episode begins: for an
    # object-recognition experiment that is one hook more than the base's.
    experiment = Map.get(callbacks, :experiment, __MODULE__)

    case experiment.pre_episode(state, index, object, callbacks) do
      {:ok, state} ->
        {outcome, infos, state} = run_episode_steps(state, callbacks)
        state = post_episode(state, outcome, infos, callbacks)
        episodes = [result(object, index, outcome, infos) | episodes]

        case outcome do
          {:crashed, _step, _reason} = crashed -> {crashed, Enum.reverse(episodes), state}
          :stopped -> {:stopped, Enum.reverse(episodes), state}
          :finished -> run_objects(rest, index + 1, state, callbacks, episodes)
        end

      {:error, reason} ->
        # The object the episode was about travels with the result, so a page can
        # say which one could not be started rather than "the run failed".
        crashed = {:crashed, 0, reason}
        {crashed, Enum.reverse([result(object, index, crashed, []) | episodes]), state}
    end
  end

  @doc """
  Monty's `pre_episode`: the episode is told what it is about.

  Answers `{:error, reason}` for a world that would not start the episode — the
  place Monty raises `ObjectNotVisibleError` — because a run that cannot begin is
  a result, not a crash.
  """
  @spec pre_episode(state, non_neg_integer(), String.t() | nil, callbacks(state, info)) ::
          {:ok, state} | {:error, term()}
        when state: term(), info: term()
  def pre_episode(state, index, object, %{pre_episode: pre_episode} = callbacks),
    do: pre_episode.(state, index, object, callbacks)

  @doc """
  Monty's `post_episode`: whatever the end of an episode owes.

  Monty increments its counters and logs the episode here; here it is the
  callbacks' answer, because the counters and the record belong to the studio.
  """
  @spec post_episode(state, outcome(), [term()], callbacks(state, info)) :: state
        when state: term(), info: term()
  def post_episode(state, outcome, infos, %{post_episode: post_episode}),
    do: post_episode.(state, outcome, infos)

  @doc """
  Steps until the policy says the episode is done, or the caller stops it.

  Monty's `run_episode_steps`, and the same loop: `_recognition_complete/2` is
  asked at the top of every iteration, so an episode that is already over takes
  no step at all.

  Answers the outcome, the reports of the steps the episode took — newest first,
  as they were collected — and the state the loop left behind. Monty's version
  answers the step count; a studio run needs the reports and the outcome too,
  because each one is shown while the run happens and the ending is what the
  record keeps.
  """
  @spec run_episode_steps(state, callbacks(state, info)) :: {outcome(), [info], state}
        when state: term(), info: term()
  def run_episode_steps(state, %{step: step, finished?: finished?, stopped?: stopped?}) do
    loop(state, step, finished?, stopped?, [])
  end

  @doc """
  Whether the episode is over, according to the experiment's own policy.

  Monty's `_recognition_complete(count)`. The counter and the model are the
  callbacks', so this delegates — and the policy's other two requests (explore,
  or time the modules out) are its own business, applied where the model is held.
  """
  @spec _recognition_complete(state, %{required(:finished?) => (state -> boolean())}) ::
          boolean()
        when state: term()
  def _recognition_complete(state, %{finished?: finished?}), do: finished?.(state)

  defp loop(state, step, finished?, stopped?, infos) do
    cond do
      # A stop lands between steps: the step being asked for is not taken, which
      # is what makes a stopped run a run that ended at a step boundary.
      stopped?.() -> {:stopped, infos, state}
      _recognition_complete(state, %{finished?: finished?}) -> {:finished, infos, state}
      true -> advance(state, step, finished?, stopped?, infos)
    end
  end

  defp advance(state, step, finished?, stopped?, infos) do
    case step.(state) do
      {:ok, info, state} -> loop(state, step, finished?, stopped?, [info | infos])
      {:error, reason} -> {{:crashed, length(infos), reason}, infos, state}
    end
  end

  defp result(object, index, outcome, infos) do
    %{object: object, episode: index, outcome: outcome, steps: length(infos)}
  end
end
