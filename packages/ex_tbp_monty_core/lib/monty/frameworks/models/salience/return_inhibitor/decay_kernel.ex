defmodule Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayKernel do
  @moduledoc """
  One place the sensor has been, and how much it still says "not here again".

  Mirrors
  `tbp/monty/frameworks/models/salience/return_inhibitor.py::DecayKernel`: a
  kernel returns the product of two exponentials — one falling with the time since
  it was created, one falling with distance from where it was created — so a
  salience module stops proposing the spot it just looked at, and stops sooner the
  further away it is looking.

  Both decays are half-lives: `tau_t` and `tau_s` are the times and distances at
  which the weight halves, so the exponent divides by `tau / ln 2`. Beyond
  `:spatial_cutoff` metres the kernel says nothing at all, which keeps a
  surface's far side free of a visit to its near side.

  Monty mutates a kernel in place; a struct here is a value, so stepping answers
  the kernel and whether it has decayed below `:w_t_min` — at which point its
  field drops it.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics

  @type location :: [float()]
  @type points :: [[float()]]

  @enforce_keys [:location]
  defstruct location: nil, tau_t: 10.0, tau_s: 0.01, spatial_cutoff: 0.02, w_t_min: 0.1, steps: 0

  @type t :: %__MODULE__{
          location: location(),
          tau_t: float(),
          tau_s: float(),
          spatial_cutoff: float() | nil,
          w_t_min: float(),
          steps: non_neg_integer()
        }

  @spec new(location(), keyword()) :: t()
  def new(location, options \\ []) do
    %__MODULE__{
      location: location,
      tau_t: Keyword.get(options, :tau_t, 10.0),
      tau_s: Keyword.get(options, :tau_s, 0.01),
      spatial_cutoff: Keyword.get(options, :spatial_cutoff, 0.02),
      w_t_min: Keyword.get(options, :w_t_min, 0.1)
    }
  end

  @doc "How much the kernel still matters, from its age alone."
  @spec time_weight(t()) :: float()
  def time_weight(%__MODULE__{} = kernel) do
    :math.exp(-kernel.steps / half_life(kernel.tau_t))
  end

  @doc """
  How much the kernel matters at each of `points`, from distance alone.

  Zero beyond the spatial cutoff, which is what makes the kernel local rather
  than merely weaker in the distance.
  """
  @spec space_weight(t(), points()) :: [float()]
  def space_weight(%__MODULE__{} = kernel, points) do
    half_life = half_life(kernel.tau_s)

    Enum.map(points, fn point ->
      distance =
        kernel.location
        |> SpatialArithmetics.subtract(point)
        |> SpatialArithmetics.magnitude()

      if kernel.spatial_cutoff != nil and distance > kernel.spatial_cutoff,
        do: 0.0,
        else: :math.exp(-distance / half_life)
    end)
  end

  @doc "The kernel's weight at each point: its age and its distance together."
  @spec weights(t(), points()) :: [float()]
  def weights(%__MODULE__{} = kernel, points) do
    time = time_weight(kernel)
    Enum.map(space_weight(kernel, points), &(time * &1))
  end

  @doc """
  One step older, and whether that was one too many.

  Monty checks the *new* weight against the minimum, so a kernel is dropped on the
  step after it falls below it.
  """
  @spec step(t()) :: {t(), boolean()}
  def step(%__MODULE__{} = kernel) do
    stepped = %__MODULE__{kernel | steps: kernel.steps + 1}
    {stepped, time_weight(stepped) < kernel.w_t_min}
  end

  defp half_life(tau), do: tau / :math.log(2)
end
