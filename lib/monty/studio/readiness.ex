defmodule Monty.Studio.Readiness do
  @moduledoc """
  Which of Monty's experiments this application can run, and what stands in the
  way of the rest.

  "Sixty of two hundred and ten" is not the useful number on its own: an
  experiment is refused because of a class this port has not written, or because
  its world is one this build does not carry, and those two are different work.
  This turns a set of opened setups into the answer a person planning the port
  needs — how many experiments each missing class would unblock **on its own**,
  and how many name it at all.

  Pure where it matters: `classify/1` reads one outcome and `summarise/1` counts
  a list of them, so both can be tested on a fixture. `catalog/1` is the impure
  edge — it opens every experiment and keeps the answer — and
  [`mix monty.readiness`](`Mix.Tasks.Monty.Readiness`) and the experiments page
  both read it, so the page and the count cannot disagree.
  """

  alias Monty.Studio
  alias Monty.Studio.{Catalog, Finding, Memory, Setup}

  @typedoc """
  One experiment's answer.

  `:runnable` is what every entry point already honours — the setup has no
  `:error` finding. `:did_not_compose` is a config this application cannot read
  at all, which is a finding about the port rather than about Monty.

  `:not_planned` is an experiment whose **world** this build does not carry —
  Monty's Habitat-Sim configs today. Habitat is on its way out upstream
  (2026-11-08), so those are postponed rather than refused: nothing here is
  missing that anybody means to write, and counting them as refusals made the
  backlog look twice its size. A world decides the status even when the config
  would also name a class this port has not written, because none of that work
  can be checked without the world.

  `:blocked_by` is the classes a run is refused on: the ones `Setup.blocking/1`
  calls `:unwritten` — no module here and nothing standing in for one — and the
  class of a learning module that refuses a config it cannot build, which is a
  written class with a gap in it rather than a missing one.
  """
  @type entry :: %{
          name: String.t(),
          status: :runnable | :refused | :not_planned | :did_not_compose,
          world: :mujoco | :habitat | nil,
          codes: [atom()],
          blocked_by: [String.t()]
        }

  @typedoc """
  What a row shows: whether it runs, and the world its config was written for.
  """
  @type label :: %{ready: String.t(), world: String.t()}

  @typedoc """
  One class, and the experiments it stands in front of.

  `experiments` are the ones it blocks **alone** — nothing else is wrong with
  them — so writing it and nothing else makes exactly those run. `naming` counts
  every refused experiment that names it.
  """
  @type ranking :: %{
          class: String.t(),
          alone: non_neg_integer(),
          naming: non_neg_integer(),
          experiments: [String.t()]
        }

  @type survey :: %{
          entries: [entry()],
          runnable: non_neg_integer(),
          refused: non_neg_integer(),
          not_planned: non_neg_integer(),
          did_not_compose: non_neg_integer(),
          by_code: [%{code: atom(), refused: non_neg_integer(), postponed: non_neg_integer()}],
          by_class: [ranking()]
        }

  @doc """
  One experiment's outcome, as `Monty.Studio.open/2` answers them.
  """
  @spec classify({String.t(), {:ok, Setup.t()} | {:error, term()}}) :: entry()
  def classify({name, {:ok, %Setup{} = setup}}) do
    errors = Finding.at(setup.findings, :error)

    %{
      name: name,
      status: status(errors, Setup.engine(setup)),
      world: Setup.engine(setup),
      codes: errors |> Enum.map(& &1.code) |> Enum.uniq() |> Enum.sort(),
      blocked_by: blocked_by(setup, errors)
    }
  end

  def classify({name, {:error, _reason}}) do
    %{
      name: name,
      status: :did_not_compose,
      world: nil,
      codes: [:does_not_compose],
      blocked_by: []
    }
  end

  # This build carries exactly one world, MuJoCo. A config that names any other —
  # Habitat, or a class like `SaccadeOnImageEnvironment` that is neither — is
  # postponed, and that is a fact about the config rather than about which world a
  # deployment selected, so it reads the same under `--world synthetic`. The
  # findings decide the rest.
  defp status([], :mujoco), do: :runnable
  defp status(_errors, :mujoco), do: :refused
  defp status(_errors, _not_carried_world), do: :not_planned

  defp blocked_by(setup, errors) do
    unwritten = for module <- Setup.blocking(setup).unwritten, do: module.class

    (unwritten ++ unbuildable_classes(errors))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A learning module the map calls written but which refuses this config names
  # its own class in the finding's `where`: that class is the work, and it is a
  # gap to close rather than a module to write.
  defp unbuildable_classes(errors) do
    for %{code: :learning_module_not_buildable, where: where} <- errors,
        is_binary(where),
        [_, class] <- [Regex.run(~r/([A-Za-z0-9_]+)\}?$/, where)],
        do: class
  end

  @doc """
  One experiment, opened and read.

  `opts` are `Monty.Studio.open/2`'s — `:conf_dir` and `:world_simulator`.
  """
  @spec classified(String.t(), keyword()) :: entry()
  def classified(name, opts \\ []) do
    case Studio.open(name, opts) do
      {:ok, %{setup: setup}} -> classify({name, {:ok, setup}})
      {:error, reason} -> classify({name, {:error, reason}})
    end
  end

  @doc """
  Every catalogue experiment's answer, from a cache.

  Reading what a config *means* is composing it, and composing all of Monty's
  costs about a second and a half — more than a page mount can pay on every
  visit. So the answer is kept until something it was computed from moves: the
  catalogue itself (`Catalog.stamp/1`), the world a setup is read for, or the
  libraries on this machine (an experiment refused for want of a pretrained
  memory stops being refused the moment one is exported).

  `opts` are `Monty.Studio.open/2`'s: `:conf_dir` and `:world_simulator`.
  """
  @spec catalog(keyword()) :: survey()
  def catalog(opts \\ []) do
    key = {__MODULE__, :catalog, Catalog.stamp(opts), world(opts), libraries_stamp()}

    case :persistent_term.get(key, nil) do
      nil ->
        survey = opts |> read_catalog() |> summarise()
        :persistent_term.put(key, survey)
        survey

      survey ->
        survey
    end
  end

  @doc """
  What a page filters on, per experiment: `ready` — `"yes"`, `"no"`, or
  `"not_planned"` — and `world` — `"mujoco"`, `"habitat"`, or `"other"` for a
  config naming no simulator this application knows.
  """
  @spec labels(survey()) :: %{String.t() => label()}
  def labels(%{entries: entries}) do
    Map.new(entries, fn entry ->
      {entry.name, %{ready: verdict(entry.status), world: world_name(entry.world)}}
    end)
  end

  defp verdict(:runnable), do: "yes"
  defp verdict(:not_planned), do: "not_planned"
  defp verdict(_refused), do: "no"

  defp world_name(:mujoco), do: "mujoco"
  defp world_name(:habitat), do: "habitat"
  defp world_name(_none), do: "other"

  @doc """
  Forgets every cached answer.

  A test that changes the world (or the libraries directory) under the cache has
  to say so; nothing in production changes either without the key moving.
  """
  @spec forget() :: :ok
  def forget do
    for {{__MODULE__, :catalog, _stamp, _world, _libraries} = key, _value} <-
          :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end

  defp read_catalog(opts) do
    open = Keyword.take(opts, [:conf_dir, :world_simulator])

    for experiment <- Catalog.experiments(Keyword.take(opts, [:conf_dir])),
        do: classified(experiment.name, open)
  end

  # What the answer depends on besides the catalogue: which world a setup is read
  # for, and which libraries are on this machine. The library listing is two
  # levels of `ls` — the release directories and the files in them — so a file
  # exported into a release that already exists moves the key too.
  defp world(opts),
    do:
      Keyword.get(opts, :world_simulator) || Application.get_env(:ex_tbp_monty, :world_simulator)

  defp libraries_stamp do
    dir = Memory.libraries_dir()

    case File.ls(dir) do
      {:ok, releases} -> {dir, Map.new(releases, &{&1, files_in(Path.join(dir, &1))})}
      _missing -> {dir, :none}
    end
  end

  defp files_in(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.sort(files)
      _missing -> []
    end
  end

  @doc """
  The counts, and the classes ranked by the experiments they alone stand in front
  of.

  Only `:refused` experiments are ranked: a class named by a config whose world
  is not carried is not work anybody has taken on, and listing it would put the
  Saccade and Omniglot families at the top of a backlog they are not in.
  """
  @spec summarise([entry()]) :: survey()
  def summarise(entries) do
    refused = Enum.filter(entries, &(&1.status == :refused))
    postponed = Enum.filter(entries, &(&1.status == :not_planned))

    %{
      entries: entries,
      runnable: count(entries, :runnable),
      refused: length(refused),
      not_planned: length(postponed),
      did_not_compose: count(entries, :did_not_compose),
      by_code: tally(refused, postponed),
      by_class: ranking(refused)
    }
  end

  defp count(entries, status), do: Enum.count(entries, &(&1.status == status))

  # One row per reason, counted against the two kinds of "does not run": a code
  # that only ever appears on a postponed experiment says the work is not ours to
  # do yet, and that has to be visible in the number rather than inferred.
  defp tally(refused, postponed) do
    refused_codes = Enum.frequencies(Enum.flat_map(refused, & &1.codes))
    postponed_codes = Enum.frequencies(Enum.flat_map(postponed, & &1.codes))

    refused_codes
    |> Map.keys()
    |> Enum.concat(Map.keys(postponed_codes))
    |> Enum.uniq()
    |> Enum.map(fn code ->
      %{
        code: code,
        refused: Map.get(refused_codes, code, 0),
        postponed: Map.get(postponed_codes, code, 0)
      }
    end)
    |> Enum.sort_by(fn %{code: code, refused: refused, postponed: postponed} ->
      {-(refused + postponed), code}
    end)
  end

  # A class that one experiment names and another does not is still the same
  # class: the answer is per class, not per (class, experiment) pair.
  defp ranking(refused) do
    refused
    |> Enum.flat_map(& &1.blocked_by)
    |> Enum.uniq()
    |> Enum.map(fn class ->
      naming = Enum.filter(refused, &(class in &1.blocked_by))
      alone = Enum.filter(naming, &blocks_alone?(&1, class))

      %{
        class: class,
        alone: length(alone),
        naming: length(naming),
        experiments: alone |> Enum.map(& &1.name) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{-&1.alone, -&1.naming, &1.class})
  end

  # "Alone" is a statement about the whole experiment: the only thing wrong with
  # it is the class, so nothing but that class has to be written.
  defp blocks_alone?(entry, class) do
    entry.blocked_by == [class] and
      entry.codes in [[:modules_not_ported], [:learning_module_not_buildable]]
  end
end
