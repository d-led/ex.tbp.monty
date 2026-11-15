defmodule ExTbpMonty.Cluster.Connect do
  @moduledoc """
  Dialling a node somebody typed: what a connect dialog asks, and what it can
  honestly answer.

  Gossip finds the nodes on one machine or one link and nothing else. A **scaled
  worker** — a machine brought up for a run, a peer across a network where
  multicast does not reach — is dialled by name, and this module is that: a
  validated name in, one sentence per name out.

  ## Why the name is checked before it is dialled

  `Node.connect/1` takes an atom, and a node name is not in the atom table until
  something puts it there. `String.to_atom/1` on what a person typed is how a text
  box becomes a leak: every distinct string that reaches it is permanent. The
  shape check below is what bounds that — `name@host`, and nothing else — and the
  atom it produces is one the person meant to type.

  ## What the three answers mean

  * `:connected` — the peer answered and is in `Node.list/0` from now on.
  * `:itself` — the name is this node's own; `Node.connect/1` says `:ignored`.
  * `:unreachable` — no answer. Three things look identical here and only a person
    can tell them apart: the peer is not running, its host cannot be reached, or
    it does not share this node's cookie. The note names all three, because a
    wrong cookie is the one nobody thinks of and the one that never says so
    itself.
  * `:no_name` — this node has no name, so it cannot dial anybody. That is a
    different sentence and a different fix, and a reader who is shown "no answer"
    for it would go looking at the other machine.
  """

  # `name@host`, where a name is what a release can be given (`monty-studio-1a2b3c`,
  # `node1`) and a host is a short name, an FQDN, or an address — including the
  # IPv6 addresses a Fly Machine is named with.
  @shape ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.:_-]*\z/

  @typedoc """
  What happened to one name.

  `:connected`, `:itself`, `:unreachable` and `:no_name` are the four answers; the
  note is the sentence a reader gets, which is the whole of what the page shows.
  """
  @type result :: %{
          name: String.t(),
          outcome: :connected | :itself | :unreachable | :no_name,
          note: String.t()
        }

  @doc """
  The names in what was typed, or the first thing in it that is not a name.

  Commas, spaces and one-per-line all mean the same thing, because a person
  copying three addresses out of a terminal will bring whatever separated them.
  """
  @spec parse(String.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    names = input |> String.split(~r/[\s,]+/, trim: true) |> Enum.reject(&(&1 == ""))

    case Enum.reject(names, &Regex.match?(@shape, &1)) do
      [] when names == [] ->
        {:error, "name a node to connect to, e.g. monty-studio-1a2b3c@10.0.0.7"}

      [] ->
        {:ok, names}

      [wrong | _] ->
        {:error,
         "#{inspect(wrong)} is not a node name — it is `name@host`, " <>
           "e.g. `monty-studio-1a2b3c@10.0.0.7` or `node2@192.168.1.7`"}
    end
  end

  def parse(_nothing) do
    {:error, "name a node to connect to, e.g. monty-studio-1a2b3c@10.0.0.7"}
  end

  @doc """
  Dials each name, and says what happened to it.

  Every name gets an answer, including the ones that could not be tried: a page
  that silently dropped what it could not do would leave a reader looking at three
  rows where they typed four.
  """
  @spec dial([String.t()]) :: [result()]
  def dial(names), do: Enum.map(names, &one/1)

  defp one(name) do
    if ExTbpMonty.Node.distributed?() do
      dialled(name)
    else
      %{name: name, outcome: :no_name, note: no_name_note()}
    end
  end

  # `Node.connect/1` takes an atom and a node name is not one until something
  # makes it one, so this is the one place a typed string becomes an atom. What
  # bounds it is `parse/1`: only `name@host` gets here, so the atoms this can
  # create are the ones a person meant to type.
  # sobelow_skip ["DOS.StringToAtom"]
  defp dialled(name) do
    case Elixir.Node.connect(String.to_atom(name)) do
      true -> %{name: name, outcome: :connected, note: "connected: it is in this node's list now"}
      :ignored -> %{name: name, outcome: :itself, note: "that is this node"}
      false -> %{name: name, outcome: :unreachable, note: unreachable_note()}
    end
  end

  # A dialled node is not remembered on purpose: a peer list that survives a
  # restart is configuration (`MONTY_SEEDS`), and a text box that silently became
  # configuration is the kind of setting nobody can find again.
  defp unreachable_note do
    "no answer: the node is not running, its host cannot be reached, or it does " <>
      "not share this node's cookie (#{ExTbpMonty.Node.cookie_source()})"
  end

  defp no_name_note do
    ExTbpMonty.Node.why_not() <> " A node with no name cannot dial another one."
  end
end
