defmodule Monty.Studio.Partition do
  @moduledoc """
  Monty's `run_parallel.py`, as a plan rather than a pool: which episodes of an
  experiment each part of a parallel run takes.

  Monty splits an experiment into one config per part and lets `num_parallel`
  processes chew through them — evaluation one config per object and rotation
  (`generate_parallel_eval_configs`), training one config per object
  (`generate_parallel_train_configs`) — and merges what the parts produced when
  they are all done. A part here is the same thing said in the studio's own
  vocabulary: a contiguous stretch of the experiment's episodes, run by one job,
  with its own record. `n` in parallel is `n` parts, and the queue's limit is
  `n`, so an experiment of ten objects evaluated fourteen times takes a
  fourteenth of the clock instead of the same experiment being started fourteen
  times over.

  Two rules, Monty's:

    * **evaluation** is divided by episode. Every episode is one object in one
      rotation, and no episode needs another, so any division of the list is a
      division of the work.
    * **training** is divided by object, and every rotation of that object stays
      in one part, in order. A training episode extends the graph the previous
      one built, so taking an object apart would be training two half objects.

  An episode's *number* is what says which object it shows, which rotation it is
  and which draws it takes (`Setup.world/4`, `Monty.Frameworks.Experiments.Seed`),
  so a part is a list of those numbers: the same numbers, in the same order, are
  the same episodes — a part that trained object two in three rotations built
  what the whole experiment would have built, and nothing has to be renumbered.

  A config that trains and then evaluates gets a training wave and an evaluation
  wave. The evaluation wave cannot start until every training part has finished
  and its memory has been merged (`Monty.Studio.Memories`), which is what
  `Monty.Studio.Jobs.Merge` waits for.

  ## What a part is not

  A part is not an episode: Monty writes one config per episode, this writes one
  record per *worker*, because a page that drew a chart and two pictures for each
  of a hundred and forty parts would be a page nobody reads. The division of the
  work is Monty's; only the number of pieces the page shows is the studio's.
  """

  alias Monty.Studio.Setup

  @typedoc """
  One part of an experiment: the episodes it runs, and which of how many it is.

  `episodes` are the experiment's own episode numbers, in the order the part
  walks them — the numbers that decide the object, the rotation and the draws.
  """
  @type part :: %{
          index: non_neg_integer(),
          of: pos_integer(),
          phase: :train | :eval,
          episodes: [non_neg_integer()]
        }

  @typedoc """
  A whole partition: the batch it belongs to, and the parts of each wave.

  `train` is empty for an evaluation-only config, and so is `eval` for a
  training-only one. Both non-empty is a config that trains first: its
  evaluation wave starts from the merged memory, not from the one the config
  names.
  """
  @type t :: %{batch: String.t(), train: [part()], eval: [part()]}

  @doc """
  The plan for `count` parts, each taking a share of the first `budget` episodes.

  A budget is what the page's "episodes" box means: how much of the experiment to
  run, counted per phase exactly as a run's own budget is (`Monty.Studio.Jobs.Run`).
  `nil` is all of it. Asking for more parts than there are episodes is answered
  with as many parts as there is work for.

  `:batch` names the plan — the id every part's record keeps, so a page can ask
  for the parts of one press of Run rather than for every run of the experiment.
  """
  @spec plan(Setup.t(), pos_integer(), pos_integer() | nil, keyword()) :: t()
  def plan(%Setup{} = setup, count, budget \\ nil, options \\ []) do
    batch = Keyword.get_lazy(options, :batch, fn -> Ecto.UUID.generate() end)

    %{
      batch: batch,
      train: phase_parts(setup, :train, count, budget),
      eval: phase_parts(setup, :eval, count, budget)
    }
  end

  @doc "Every part of a plan, in the order the waves run: training first."
  @spec parts(t()) :: [part()]
  def parts(%{train: train, eval: eval}), do: train ++ eval

  @doc """
  Whether the evaluation wave waits for the training one.

  A config that only evaluates waits for nothing; one that trains and then
  evaluates has a merge between its waves (`Monty.Studio.Jobs.Merge`), because
  its evaluation has to read what its training built.
  """
  @spec two_waves?(t()) :: boolean()
  def two_waves?(%{train: [_ | _], eval: [_ | _]}), do: true
  def two_waves?(_one_wave), do: false

  @doc """
  How many episodes of `phase` the experiment is, whatever the budget.

  Monty's `run_epoch` walks each phase's own object list, so a config that trains
  on two objects and evaluates one is six training episodes and three evaluation
  ones.
  """
  @spec episodes(Setup.t(), :train | :eval) :: non_neg_integer()
  def episodes(%Setup{} = setup, :train) do
    length(Setup.objects(setup, :train)) * (Setup.train_epochs(setup) || 0)
  end

  def episodes(%Setup{} = setup, :eval) do
    length(Setup.objects(setup, :eval)) * Setup.eval_epochs(setup)
  end

  # A phase the config switches off has no parts: `do_train: false` with a count
  # of three is a phase the experiment never runs.
  defp phase_parts(setup, phase, count, budget) do
    case {phase, switched_on?(setup, phase)} do
      {:train, true} -> by_object(setup, count, budget)
      {:eval, true} -> by_episode(setup, count, budget)
      {_off, false} -> []
    end
  end

  defp switched_on?(setup, :train), do: Setup.do_train(setup)
  defp switched_on?(setup, :eval), do: Setup.do_eval(setup)

  # Evaluation: the episodes are independent, so the list is cut into `count`
  # stretches of about the same length.
  defp by_episode(setup, count, budget) do
    taken = taken(setup, :eval, budget)

    taken
    |> indices()
    |> chunk(min(count, taken))
    |> numbered(:eval)
  end

  # Training: an object's rotations stay together and in order, because a
  # training episode extends the graph the one before it built. Fewer parts than
  # objects means the parts take objects in turn — every object is still trained
  # by exactly one part.
  defp by_object(setup, count, budget) do
    objects = length(Setup.objects(setup, :train))
    taken = taken(setup, :train, budget)
    parts = objects |> min(taken) |> min(count)

    if parts == 0 do
      []
    else
      for part <- 0..(parts - 1) do
        for index <- indices(taken), rem(rem(index, objects), parts) == part, do: index
      end
      |> numbered(:train)
    end
  end

  # How many of a phase's episodes this plan runs: the budget, or the phase.
  defp taken(setup, phase, nil), do: episodes(setup, phase)
  defp taken(setup, phase, budget), do: min(budget, episodes(setup, phase))

  defp indices(0), do: []
  defp indices(taken), do: Enum.to_list(0..(taken - 1))

  # `count` stretches of about the same length: the first ones take the extra
  # episodes, so a part is at most one episode longer than its neighbour.
  defp chunk([], _count), do: []

  defp chunk(episodes, count) do
    size = div(length(episodes) + count - 1, count)
    Enum.chunk_every(episodes, size)
  end

  # One part per stretch, numbered in the order the phase walks them: "part 2 of
  # 4" has to mean the second stretch of the experiment, not the second one a
  # page happened to render.
  defp numbered(stretches, phase) do
    of = length(stretches)

    for {episodes, place} <- Enum.with_index(stretches) do
      %{index: place, of: of, phase: phase, episodes: episodes}
    end
  end
end
