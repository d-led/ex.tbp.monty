defmodule ExTbpMonty.Objaverse.Corpus do
  @moduledoc """
  Whether the objects a corpus was imported into are comparable.

  A learning module matches a percept against a memory built from **every**
  object of the corpus, at one voxel size and one patch size. Two objects that
  differ in size therefore do not differ as objects: the patch covers a larger
  fraction of the small one, its graph collects more nodes per square centimetre,
  and its evidence climbs faster. Recognition over such a corpus is a ranking of
  graph density, and the densest graph wins every episode.

  The import cannot fix that — it normalises each object to one height, and dogs
  that are long and low and dogs that are tall and compact reach that height at
  very different footprints. What it can do is say so, which is what this module
  is for: one number a person reads before trusting a corpus.

  The measure is the **footprint** — the horizontal extent of what the world will
  see, in metres — because that is the plane a surface agent walks and a distant
  agent lands on. Two rows of `{0.05, 0.06, 0.10}` and `{0.06, 0.05, 0.10}`
  footprints of 6 cm each are one corpus; 4.7 cm against 23.5 cm is not, and
  `outliers/1` names the second.

  """

  @typedoc """
  `rows` are the import's own rows: `:id` and `:size` as `{x, y, z}` in metres.
  """
  @type row :: %{required(:id) => String.t(), required(:size) => {float(), float(), float()}}

  @typedoc """
  `spread` is widest footprint divided by the median one, and `outliers` are the
  objects above `limit` times the median — the ones the patch sees least of.
  """
  @type report :: %{
          footprints: %{String.t() => float()},
          median: float(),
          widest: {String.t(), float()},
          narrowest: {String.t(), float()},
          spread: float(),
          outliers: [String.t()]
        }

  @doc """
  How far apart the corpus's footprints are.

  A corpus of one object is comparable with itself and says so.
  """
  @spec report([row()]) :: report()
  def report(rows) do
    footprints = footprints(rows)
    sizes = footprints |> Map.values() |> Enum.sort()

    median = median(sizes)
    widest = footprints |> Enum.max_by(&elem(&1, 1))
    narrowest = footprints |> Enum.min_by(&elem(&1, 1))

    %{
      footprints: footprints,
      median: median,
      widest: widest,
      narrowest: narrowest,
      spread: if(median > 0, do: elem(widest, 1) / median, else: 0.0),
      outliers: for({id, size} <- footprints, size > median * limit(), do: id)
    }
  end

  @doc """
  Whether `report/1` calls a corpus comparable: no object above `limit/0` times
  the median footprint, and none below its reciprocal.

  A corpus of one object is comparable with itself and says so.
  """
  @spec comparable?(report()) :: boolean()
  def comparable?(%{footprints: footprints}) when map_size(footprints) < 2, do: true

  def comparable?(%{median: median, footprints: footprints}) do
    sizes = Map.values(footprints)
    Enum.max(sizes) <= median * limit() and Enum.min(sizes) >= median / limit()
  end

  @doc """
  How far apart two footprints may be before a patch cannot treat them alike.

  Two, because a patch's coverage falls with the square of the object's size: at
  twice the footprint the same patch sees a quarter of the object, which is
  already a different experiment.
  """
  @spec limit() :: float()
  def limit, do: 2.0

  @doc "The footprint of each row: the larger of its two horizontal extents."
  @spec footprints([row()]) :: %{String.t() => float()}
  def footprints(rows) do
    Map.new(rows, fn %{id: id, size: {x, y, _z}} -> {id, max(x, y)} end)
  end

  defp median([]), do: 0.0

  defp median(sizes) do
    count = length(sizes)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sizes, middle)
    else
      (Enum.at(sizes, middle - 1) + Enum.at(sizes, middle)) / 2
    end
  end
end
