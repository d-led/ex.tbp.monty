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

  The measure is the **surface area**, in square metres, because that is what a
  memory's node count follows: the import normalises each object to one area, and
  a corpus whose areas still differ is one where a patch fills one graph faster
  than another. The footprint travels with the report because it is what a motor
  policy has to walk — an object 24 cm long and one 5 cm long are the same
  experiment to a memory and a very different one to a gait — but it is not what
  makes a corpus comparable.

  """

  @typedoc """
  `rows` are the import's own rows: `:id`, the `:area` in square metres and the
  `:size` as `{x, y, z}` in metres.
  """
  @type row :: %{
          required(:id) => String.t(),
          required(:size) => {float(), float(), float()},
          optional(:area) => float() | nil
        }

  @typedoc """
  `spread` is the widest area divided by the median one, and `outliers` are the
  objects above `limit` times the median — the ones whose graph fills fastest.
  """
  @type report :: %{
          areas: %{String.t() => number()},
          footprints: %{String.t() => number()},
          median: number(),
          widest: {String.t(), number()},
          narrowest: {String.t(), number()},
          spread: number(),
          outliers: [String.t()]
        }

  @doc """
  How far apart the corpus's objects are, by surface area.

  A corpus of one object is comparable with itself and says so.
  """
  @spec report([row()]) :: report()
  def report(rows) do
    areas = areas(rows)
    pairs = Map.to_list(areas)
    sizes = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    median = median(sizes)
    {widest, narrowest} = extremes(pairs)
    outliers = outliers(pairs, median)

    %{
      areas: areas,
      footprints: footprints(rows),
      median: median,
      widest: widest,
      narrowest: narrowest,
      spread: if(median > 0, do: elem(widest, 1) / median, else: 0.0),
      outliers: outliers
    }
  end

  @doc """
  Whether `report/1` calls a corpus comparable: no object above `limit/0` times
  the median area, and none below its reciprocal.

  A corpus of one object is comparable with itself and says so.
  """
  @spec comparable?(map()) :: boolean()
  def comparable?(%{areas: areas}) when map_size(areas) < 2, do: true

  def comparable?(%{median: median, areas: areas}) do
    sizes = Map.values(areas)
    Enum.max(sizes) <= median * limit() and Enum.min(sizes) >= median / limit()
  end

  @doc """
  How far apart two areas may be before a patch cannot treat them alike.

  Two, because coverage falls with the square of the object's size: at twice the
  area the same patch sees half the object in a view, and its graph fills twice
  as slowly.
  """
  @spec limit() :: float()
  def limit, do: 2.0

  @doc "The surface area of each row, in square metres."
  @spec areas([row()]) :: %{String.t() => float()}
  def areas(rows) do
    for %{id: id} = row <- rows, into: %{} do
      {id, Map.get(row, :area) || 0.0}
    end
  end

  @doc "The footprint of each row: the larger of its two horizontal extents."
  @spec footprints([row()]) :: %{String.t() => float()}
  def footprints(rows) do
    for %{id: id, size: {x, y, _z}} <- rows, into: %{}, do: {id, max(x, y)}
  end

  @spec median([number()]) :: float()
  defp median([]), do: 0.0

  defp median(sizes) do
    count = length(sizes)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sizes, middle, 0.0)
    else
      (Enum.at(sizes, middle - 1, 0.0) + Enum.at(sizes, middle, 0.0)) / 2
    end
  end

  # The objects whose graph fills faster than the rest: more than `limit/0` times
  # the median area, which is the whole of what "not comparable" means here.
  @spec outliers([{String.t(), number()}], number()) :: [String.t()]
  defp outliers(pairs, median) do
    for {id, area} <- pairs, area > median * limit(), do: id
  end

  # The largest and smallest areas with the object each belongs to, and nothing
  # at all for a corpus that has no objects yet.
  @spec extremes([{String.t(), number()}]) :: {{String.t(), number()}, {String.t(), number()}}
  defp extremes([]), do: {{"", 0.0}, {"", 0.0}}

  defp extremes([{id, area} | rest]) do
    Enum.reduce(rest, {{id, area}, {id, area}}, fn {other, size}, {widest, narrowest} ->
      {
        if(size > elem(widest, 1), do: {other, size}, else: widest),
        if(size < elem(narrowest, 1), do: {other, size}, else: narrowest)
      }
    end)
  end
end
