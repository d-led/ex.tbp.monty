defmodule Monty.ModuleMap.StandIns do
  @moduledoc """
  What this application runs in place of a Monty class it has not written.

  Two things do, and nothing else:

    * **the runtime** does the job of Monty's shell — `Monty`, which owns the
      sensor modules, the learning modules and the motor system, and
      `MontyForGraphMatching`, which owns the matching step and the vote round.
      Here those are processes (`Monty.Runtime.Model`) stepped by
      `Monty.Runtime.Step`, and the episode belongs to `Monty.Studio.Run`. That
      is a replacement on purpose, not a hole: the job is done.
    * **the carried MuJoCo world** — Monty's `MuJoCoSimulator` and its scene
      classes execute here as Python in `priv/monty_py/world.py`, in the
      interpreter this application embeds. The code runs; it is just not Elixir.

  A class in neither list has **no** stand-in, and a config naming it is
  refused: an unwritten class is an error rather than a fake run wearing the
  experiment's name (`Monty.Studio.Setup`'s findings say so on the page).

  This module is the one place the answer is written down. `mix
  monty.module_map.gen` copies it into the map as `stand_in` on each class, and
  everything else — the studio's findings, `/modules` — reads it from there, so
  a page and a refusal cannot disagree about what runs.
  """

  @shell_classes ["Monty", "MontyForGraphMatching"]

  @shell_stand_ins [
    %{
      kind: :module,
      name: Monty.Runtime.Model,
      why: "owns the modules a config names, as supervised processes"
    },
    %{
      kind: :module,
      name: Monty.Runtime.Step,
      why: "steps them: the matching step, the vote round, the terminal checks"
    }
  ]

  # Monty's MuJoCo simulator and environment classes. Recognised by the package
  # they live in, in either spelling: the map's entries carry a file path
  # (`simulators/mujoco/simulator.py`) and a resolved class carries a dotted
  # module path (`tbp.monty.simulators.mujoco.simulator`).
  @world_markers [".simulators.mujoco.", "simulators/mujoco/"]

  @world_stand_in [
    %{
      kind: :file,
      path: "priv/monty_py/world.py",
      why: "MuJoCo scene and simulator, carried as Python in the embedded interpreter"
    }
  ]

  @doc "The classes whose job the runtime does, by Monty's own name for each."
  @spec shell_classes() :: [String.t()]
  def shell_classes, do: @shell_classes

  @doc "Whether this class is one whose job the runtime does."
  @spec shell?(String.t()) :: boolean()
  def shell?(class), do: class in @shell_classes

  @doc """
  Whether a class of this Python file is one the carried world implements.

  `python` is either the file path inside the package, as the map records it, or
  the dotted module path of a resolved class.
  """
  @spec in_the_world?(String.t() | nil) :: boolean()
  def in_the_world?(python) when is_binary(python),
    do: Enum.any?(@world_markers, &String.contains?(python, &1))

  def in_the_world?(_python), do: false

  @doc """
  What runs in place of this class, or `[]` when nothing does.

  The answer is data — `kind: :module` naming an Elixir module that exists, or
  `kind: :file` naming a path in this repository — with a sentence saying why,
  because "replaced" and "missing" look the same from a table and mean
  opposite things for a reader deciding whether an experiment can run.
  """
  @spec for_class(String.t(), String.t() | nil) :: [map()]
  def for_class(class, python) do
    cond do
      shell?(class) -> @shell_stand_ins
      in_the_world?(python) -> @world_stand_in
      true -> []
    end
  end
end
