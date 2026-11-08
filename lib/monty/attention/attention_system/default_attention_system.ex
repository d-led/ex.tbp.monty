defmodule Monty.Attention.AttentionSystem.DefaultAttentionSystem do
  @moduledoc """
  Attention that learns where looking has paid off: Monty's
  `attention/attention_system.py::DefaultAttentionSystem`.

  Each step it turns the sensor's proposed regions into a sparse grid of weights,
  lets the previous grid decay, drops the voxels that have faded to nothing, and
  merges the new grid into the old one. The merged grid is then what the goal
  filter reads, so a goal is weighed against everything attention has seen, not
  just against this step's proposal.

  The pipeline, in Monty's order:

      proposed = regions → voxels → one pooled weight per voxel
      step:  proposed → telemetry
             decay(grid) → expire → merge(expired, proposed) → telemetry
             goal_filter(grid, goals) → goals

  `expire/1` is the part that makes the grid a memory rather than an
  accumulator: a weight whose magnitude has decayed below `1e-6` is dropped, so a
  place that has not been looked at for long enough stops being a voxel at all.

  The collaborators — `weight_pooler`, `decay`, `merge`, `goal_filter` — are
  functions, which is this port's form of Monty's one-method protocols; `new/1`
  turns a decay value into one for you. `telemetry` is a value it threads, because
  telemetry is the one collaborator with state of its own.
  """

  @behaviour Monty.Attention.AttentionSystem

  alias Monty.Attention.{Decay, GoalFilter, VoxelGrid, WeightPooler}

  alias Monty.Attention.Decay.LinearWeightDecay
  alias Monty.Attention.Merge.Union
  alias Monty.Attention.Telemetry.NoopAttentionSystemTelemetry
  alias Monty.Cmp.{AttentionRegion, Goal}

  @default_voxel_size 0.05

  @weight_expiration_tolerance 1.0e-6

  @enforce_keys [:voxel_size, :weight_pooler, :decay, :merge, :goal_filter, :telemetry, :grid]
  defstruct [:voxel_size, :weight_pooler, :decay, :merge, :goal_filter, :telemetry, :grid]

  @typedoc """
  A weight pooler: many weights about one voxel in, one weight out.
  """
  @type weight_pooler :: ([number()] -> number())

  @typedoc "A decay: a grid in, the same grid one step closer to zero out."
  @type decay :: (VoxelGrid.t() -> VoxelGrid.t())

  @typedoc "A merge: two grids in, one grid out."
  @type merge :: (VoxelGrid.t(), VoxelGrid.t() -> VoxelGrid.t())

  @typedoc "A goal filter: what attention knows, and the goals, in; goals to pursue, out."
  @type goal_filter :: (VoxelGrid.t(), [Goal.t()] -> [Goal.t()])

  @type t :: %__MODULE__{
          voxel_size: float(),
          weight_pooler: weight_pooler(),
          decay: decay(),
          merge: merge(),
          goal_filter: goal_filter(),
          telemetry: term(),
          grid: VoxelGrid.t()
        }

  @doc """
  A system that has learned nothing yet.

  Defaults are Monty's: 5 cm voxels, `negative_priority_max_pool`, linear decay at
  Monty's default rate, `Union`, `HardGoalFilter`, and telemetry that records
  nothing.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    voxel_size = Keyword.get(options, :voxel_size, @default_voxel_size)

    %__MODULE__{
      voxel_size: voxel_size,
      weight_pooler:
        Keyword.get(options, :weight_pooler, &WeightPooler.negative_priority_max_pool/1),
      decay: options |> Keyword.get(:decay, default_decay()) |> as_decay(),
      merge: Keyword.get(options, :merge, &Union.merge/2),
      goal_filter: Keyword.get(options, :goal_filter, &GoalFilter.HardGoalFilter.filter/2),
      telemetry: Keyword.get(options, :telemetry, %NoopAttentionSystemTelemetry{}),
      grid: VoxelGrid.empty(voxel_size)
    }
  end

  defp default_decay,
    do: %LinearWeightDecay{rate: Decay.default_linear_weight_decay_rate()}

  # Monty's bound `__call__`: a decay value becomes a function of one grid.
  defp as_decay(%module{} = decay), do: fn grid -> module.decay(decay, grid) end
  defp as_decay(decay) when is_function(decay, 1), do: decay

  @doc "The weight magnitude below which a voxel is dropped from the grid."
  @spec weight_expiration_tolerance() :: float()
  def weight_expiration_tolerance, do: @weight_expiration_tolerance

  @doc """
  Act on one step: learn where the sensors looked, and say which goals survive.

  Answers the system to use next step plus the goals worth pursuing. The goals go
  through the goal filter after the merge, so they are judged against the memory
  including this step's proposals.
  """
  @impl Monty.Attention.AttentionSystem
  def step(%__MODULE__{} = system, goals, regions) do
    proposed = attention_grid(system, regions)
    telemetry = record(system.telemetry, :proposed_grid, proposed)

    grid =
      system.grid
      |> system.decay.()
      |> expire()
      |> system.merge.(proposed)

    system = %{system | grid: grid, telemetry: record(telemetry, :grid, grid)}

    {system, system.goal_filter.(grid, goals)}
  end

  @doc "Forget every voxel and everything the telemetry recorded."
  @impl Monty.Attention.AttentionSystem
  def reset(%__MODULE__{} = system) do
    %{
      system
      | grid: VoxelGrid.empty(system.voxel_size),
        telemetry: record(system.telemetry, :reset)
    }
  end

  @doc "The grid attention has built, and what the telemetry recorded."
  @impl Monty.Attention.AttentionSystem
  def state_dict(%__MODULE__{} = system) do
    %{grid: system.grid, telemetry: record(system.telemetry, :state_dict)}
  end

  @doc """
  The grid without the voxels whose weight has faded below the tolerance.

  A weight whose magnitude is under `1e-6` says nothing worth remembering, and
  keeping it would keep the grid growing forever.
  """
  @spec expire(VoxelGrid.t()) :: VoxelGrid.t()
  def expire(%VoxelGrid{} = grid) do
    remembered =
      grid.weights
      |> Enum.reject(fn {_voxel, weight} -> abs(weight) < @weight_expiration_tolerance end)
      |> Map.new()

    %{grid | weights: remembered}
  end

  # Monty's `_voxelize_attention_regions`: the regions as one grid, one pooled
  # weight per voxel.
  defp attention_grid(%__MODULE__{voxel_size: voxel_size} = system, regions) do
    region = AttentionRegion.concat(regions)

    if region.locations == [] do
      VoxelGrid.empty(voxel_size)
    else
      {voxels, weights} =
        voxel_size
        |> VoxelGrid.voxelize_and_bin_points(region.locations, region.weights)
        |> pool(system.weight_pooler)
        |> Enum.unzip()

      VoxelGrid.new(voxel_size, voxels, weights)
    end
  end

  # Monty's `_pool_weights`: a group per voxel, aggregated by the pooler. Sorted by
  # voxel, which is what pandas' groupby does and what makes a grid reproducible.
  defp pool(pairs, weight_pooler) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {voxel, weights} -> {voxel, weight_pooler.(weights)} end)
  end

  defp record(telemetry, event), do: apply(telemetry.__struct__, event, [telemetry])
  defp record(telemetry, event, grid), do: apply(telemetry.__struct__, event, [telemetry, grid])
end
