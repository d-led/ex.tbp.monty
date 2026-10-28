defmodule Monty.Frameworks.Utils.CommunicationUtils do
  @moduledoc """
  Reading what came in over one channel.

  Mirrors `tbp/monty/frameworks/utils/communication_utils.py`. A module given a
  step's percepts gets them as a list, because a step can carry several — a
  motor-only step carries none, a step where two sensors saw the object carries
  two — and what a caller usually wants is the one from a particular channel.

  Naming a channel that is not in the percepts is an error rather than a `nil`:
  a caller asking for a channel it expected and not finding it has a bug, and
  the error says which channel and what was there instead.
  """

  alias Monty.Cmp.Message

  @doc """
  The percept from `channel_name`, or an error naming the channels that did
  arrive.
  """
  @spec get_percept_from_channel([Message.t()], String.t()) ::
          {:ok, Message.t()} | {:error, {:channel_not_found, String.t(), [String.t()]}}
  def get_percept_from_channel(percepts, channel_name) do
    case Enum.find(percepts, &(&1.sender_id == channel_name)) do
      nil ->
        {:error, {:channel_not_found, channel_name, Enum.map(percepts, & &1.sender_id)}}

      percept ->
        {:ok, percept}
    end
  end
end
