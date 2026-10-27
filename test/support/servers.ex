defmodule Monty.Test.EchoServer do
  @moduledoc "Replies to everything; used to test barriers."

  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(request, _from, state), do: {:reply, {:echo, request}, state}
end

defmodule Monty.Test.SilentServer do
  @moduledoc """
  Never replies to `:send_out_vote`.

  Stands in for a module that is too slow to vote; a barrier with a deadline
  must return without it, and say so.
  """

  use GenServer

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call(:send_out_vote, _from, state), do: {:noreply, state}
  def handle_call(request, _from, state), do: {:reply, request, state}
end
