defmodule Monty.Studio.Pretrained.Torch do
  @moduledoc """
  One of Monty's `model.pt` files, read without torch.

  `model.pt` is a torch save: a zip holding a pickle and the raw bytes of every
  storage the pickle refers to. Reading it therefore needs two things torch
  does — an unpickler, and the storages, which a pickle names by key rather than
  carrying. `Unpickler` does the first; this module answers the second and turns
  the tensors into `Monty.Studio.Pretrained.Tensor`s.

  Nothing else in the pickle is interpreted. Monty's classes
  (`GraphObjectModel`, `Data`, `GlobalStorage`) come back as `Unpickler.Object`s
  with their attribute maps intact, and the caller walks them; a class this
  module has never seen is one more object, not an error. That is what keeps the
  read to what it is for: the numbers in a graph, and nothing about how Monty
  computes with them.
  """

  alias Monty.Studio.Pretrained.{Numpy, Tensor}
  alias Unpickler.Object

  # torch's storage classes, and the numbers inside them. A class that is not
  # here is a model this reader does not understand, which is worth saying out
  # loud rather than decoding as bytes.
  @element_types %{
    "FloatStorage" => :f32,
    "DoubleStorage" => :f64,
    "LongStorage" => :i64
  }

  @doc """
  The pickle inside a `model.pt`, with its tensors as `Tensor`s.

  Everything else in the term is as the pickle had it: maps, lists, tuples and
  `Unpickler.Object`s.
  """
  @spec load!(Path.t()) :: term()
  def load!(path) do
    members = members!(path)
    prefix = prefix(members)
    check_byteorder!(members, prefix)

    {term, ""} =
      Unpickler.load!(Map.fetch!(members, prefix <> "data.pkl"),
        persistent_id_resolver: &storage(&1, members, prefix),
        object_resolver: &object/1
      )

    term
  end

  # Every member of the zip in memory. A model is tens of megabytes and is read
  # once, so unpacking it beside itself would leave a second copy on disk.
  defp members!(path) do
    case :zip.unzip(to_charlist(path), [:memory]) do
      {:ok, entries} ->
        Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end)

      {:error, reason} ->
        raise ArgumentError, "cannot read #{path} as a torch save: #{inspect(reason)}"
    end
  end

  # Which directory in the zip the save was written under ("model/",
  # "archive/", …). torch picks one per save, so it is found rather than assumed.
  defp prefix(members) do
    members
    |> Map.keys()
    |> Enum.find(&String.ends_with?(&1, "data.pkl"))
    |> case do
      nil -> raise ArgumentError, "no data.pkl in the archive: not a torch save"
      name -> String.replace_suffix(name, "data.pkl", "")
    end
  end

  defp check_byteorder!(members, prefix) do
    case members[prefix <> "byteorder"] do
      "big" -> raise ArgumentError, "a big-endian torch save is not one this reads"
      _little_or_absent -> :ok
    end
  end

  # A storage the pickle refers to by key. `numel` is how many numbers it holds;
  # the member may be longer (torch pads for alignment), so the count is kept
  # with the bytes and the extra is never read.
  defp storage({"storage", %Unpickler.Global{name: name}, key, _location, count}, members, prefix) do
    type =
      Map.get(@element_types, name) ||
        raise ArgumentError, "a #{name} is not a storage this reads"

    %Tensor{
      type: type,
      count: count,
      size: [count],
      strides: [1],
      storage: bytes!(members, prefix, key)
    }
  end

  defp storage(other, _members, _prefix) do
    raise ArgumentError, "unexpected persistent id in a torch save: #{inspect(other)}"
  end

  defp bytes!(members, prefix, key) do
    case members[prefix <> "data/" <> key] do
      nil -> raise ArgumentError, "the pickle names storage #{key}, which is not in the archive"
      bytes -> bytes
    end
  end

  # A tensor is a storage plus where its first number is and how the rest are
  # laid out in it — the whole of what `_rebuild_tensor_v2` does in torch.
  defp object(%Object{
         constructor: "torch._utils._rebuild_tensor_v2",
         args: [%Tensor{} = storage, offset, size, strides | _rest]
       }) do
    {:ok, %{storage | offset: offset, size: dimensions(size), strides: dimensions(strides)}}
  end

  # A numpy array settles the same contract as a torch tensor: a shape, a float
  # or integer type, and the bytes. `Numpy` refuses a dtype it does not know by
  # name, which is the difference between "add this release" and "matches
  # nothing for reasons nobody can see".
  defp object(other) do
    case Numpy.tensor(other) do
      {:ok, tensor} -> {:ok, tensor}
      :error -> :error
    end
  end

  # torch writes a shape as a tuple, and a `torch.Size` is a tuple too, so both
  # a list and a size object arrive here.
  defp dimensions(%Object{constructor: "torch.Size", args: [dimensions]}),
    do: dimensions(dimensions)

  defp dimensions(dimensions) when is_list(dimensions), do: dimensions
  defp dimensions(dimensions) when is_tuple(dimensions), do: Tuple.to_list(dimensions)
end
