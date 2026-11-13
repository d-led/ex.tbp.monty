defmodule ExTbpMonty.Cluster.Protocol do
  @moduledoc """
  The contract a node speaks, as distinct from the build it is.

  A cluster is not made only of nodes of one build. A plugin host answers the same
  questions from its own registry (`MontyPlugin.Registry.identity/0`), a node that
  steps a CAD part may be one release behind, and a sensor, motor or learning
  process may be asked for by a node it has never met. The *version* of a node says
  which code it runs; the *protocol* says what it can be asked, and it changes far
  less often.

  Two rules follow, and they are deliberately different:

    * a part of a run may only be handed to a node whose version matches
      (`Monty.Studio.Partition`), because the record that travels with it is this
      build's shape;
    * a request may only be served between nodes whose protocol matches
      (`compatible?/1`), because that is the shape of the question and of the
      answer — and a node that answers a protocol it does not speak fails half-way
      through the work instead of at the door.

  `Monty.Studio.Jobs.Run.perform_part/4` is that door: it refuses a caller of
  another protocol with `{:incompatible_peer, theirs, ours}`, which is a line in a
  run's log rather than a `FunctionClauseError` inside a part.
  """

  @version 1

  @doc "The protocol this build speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  What this node tells a peer about the contract it speaks — the caller's half of
  a request (`perform_part/4`).
  """
  @spec local() :: %{protocol: pos_integer()}
  def local, do: %{protocol: @version}

  @doc """
  Whether `entry` — a node's identity, a node's entry in the cluster list, or a
  caller's descriptor — speaks this protocol.

  A peer that did not say is not compatible: a build that has no protocol is a
  build whose answer is of another shape, and "probably the same" is not a fact to
  hand a part of a run to.
  """
  @spec compatible?(map() | nil) :: boolean()
  def compatible?(%{protocol: @version}), do: true
  def compatible?(_other), do: false

  @doc "The protocol an identity or an entry names, or `nil` when it named none."
  @spec of(map() | nil) :: non_neg_integer() | nil
  def of(%{protocol: protocol}), do: protocol
  def of(_entry), do: nil

  @doc ~S(A protocol as a person writes it, e.g. `"monty-cluster/1"`.)
  @spec describe(map() | nil) :: String.t()
  def describe(entry) do
    case of(entry) do
      nil -> "unknown protocol"
      version -> "monty-cluster/#{version}"
    end
  end
end
