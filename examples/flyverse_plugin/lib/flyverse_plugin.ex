defmodule FlyversePlugin do
  @moduledoc """
  A spiking connectome as an Elixir Monty Studio plugin.

  A studio run is assembled from modules that need not live in the same node —
  an **experiment**, the **learning modules** it steps, and the **motor
  policies** that decide where to sense next (`MontyPlugin`). This application
  offers two of the three, and the one it leaves out is left out on purpose.

  | Plugin | Kind | What decides |
  | --- | --- | --- |
  | `FlyversePlugin.Experiment` | `:experiment` | the run it asks for, as data |
  | `FlyversePlugin.Policy` | `:motor_policy` | where the sensor goes next, by stepping flyverse's leaky integrate-and-fire connectome in Rust |

  The engine is [flyverse](https://github.com/djmango/flyverse)'s, not a copy of
  it: `native/flyverse_nif` depends on that crate at a pinned commit and calls
  `pack::Connectome::load` and `lif::Lif::step`, so the spikes this policy turns
  with are the spikes `flyverse serve` steps. `docs/research.md` is the study
  this example came out of — what is usable in flyverse, what is not, and why.

  ## Why a motor policy, and not a learning module

  A motor policy is called **once per step**, and that is what makes it callable
  across a cluster: the state that has to stay put is one simulation, and the
  value that travels is its name. `:owner_only` says exactly that, and this is
  the worked example of it.

  A learning module is the opposite: a step asks it thousands of times over
  hypotheses and a k-d tree, so a node that runs a run must *have* its code, and
  the contract says so by refusing to route one. That rules the kind out, but the
  reason not to offer one goes further: a connectome does not answer "how much
  evidence does this hypothesis have". It answers with spikes. Mapping a spike
  rate onto Monty's evidence would be a number invented here and labelled as
  belonging to a fly — so this plugin advertises nothing it cannot answer, and
  the config's own learning module is what steps the run.

  ## Why not a world

  A world is not a plugin kind; it is a core noun. `Monty.Studio.Setup` picks one
  of `:synthetic`, `:mujoco` and `:cad`, and a CAD part became one by adding a
  clause there. flyverse *has* a world — `sim.rs` steps a body in a 600 × 440 mm
  room with wing aerodynamics and a retinotopic retina — and nothing in that is
  unreachable in principle: it is the same pure Rust. What stops it today is that
  flyverse's library face exports three files (`lif`, `npy`, `pack`), so `room`,
  `body`, `wing` and `vision` are not linkable from a NIF until that crate
  exports them. That is an upstream change plus a `Setup.world/4` clause, named
  here rather than pretended; `docs/research.md` §4 has the shape of it.

  ## Names

  A plugin's name is cluster-wide — `:pg` groups by kind *and* name — so both
  carry the host that owns them: `flyverse_plugin.lif_steering` and
  `flyverse_plugin.10simobj_surf_agent`.
  """

  @plugins [FlyversePlugin.Experiment, FlyversePlugin.Policy]

  @doc "The plugins this node offers, one process each."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  This application's version, which is what a description reports.

  Read rather than written twice: `describe/0` is a function, so the version a
  cluster sees is the version in `mix.exs` at the moment it asked.
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:flyverse_plugin, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
