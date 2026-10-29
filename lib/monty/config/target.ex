defmodule Monty.Config.Target do
  @moduledoc """
  The Elixir module a `_target_` names.

  Monty's Hydra configs build objects by naming classes:

       policy:
         _target_: tbp.monty.frameworks.models.motor_policies.SurfacePolicyCurvatureInformed
         alpha: 0.1

  Composing that config keeps the name (`Monty.Config.Resolvers` returns
  `${monty.class:...}` as a dotted path), so building the object means turning
  that path into a module here — through `Monty.ModuleMap`, which is generated
  from Monty's source and therefore knows whether the class is ported at all.

  A class this port has not written is an error rather than a silent stand-in:
  a run built from a config must be a run of *that* config, and a policy that
  quietly became something else would make the experiment a lie.
  """

  alias Monty.Config.Resolvers
  alias Monty.ModuleMap

  @doc """
  The module `config` targets.

  Accepts a config map with `_target_`, or the dotted path on its own.
  """
  @spec class!(map() | String.t()) :: module()
  def class!(%{"_target_" => target}), do: class!(target)

  def class!(dotted) when is_binary(dotted) do
    python = unwrap(dotted)

    case ModuleMap.resolve(python) do
      {:ok, %{status: :implemented, elixir: elixir}} ->
        Module.concat([elixir])

      {:ok, %{status: :unknown}} ->
        raise ArgumentError, "#{python} is not a class Monty's source has"

      {:ok, %{status: status, elixir: elixir}} ->
        raise ArgumentError, not_ported(elixir, status)

      :error ->
        raise ArgumentError, "#{python} is not a file Monty's source has"
    end
  end

  @doc """
  Whether every `_target_` in a config tree names a module this port has.

  Only the strings that name a class are looked at: a config's parameters are
  mostly ordinary strings (`agent_id_0`, `all`), and treating those as class
  names would call every experiment unbuilt.
  """
  @spec implemented?(term()) :: boolean()
  def implemented?(value) when is_binary(value) do
    if class_reference?(value), do: ported?(unwrap(value)), else: true
  end

  def implemented?(value) when is_list(value), do: Enum.all?(value, &implemented?/1)

  def implemented?(%{"_target_" => target} = config),
    do: ported?(unwrap(target)) and implemented?(Map.delete(config, "_target_"))

  def implemented?(%{} = config), do: config |> Map.values() |> implemented?()
  def implemented?(_scalar), do: true

  defp class_reference?("${monty.class:" <> _rest), do: true
  defp class_reference?("tbp." <> _rest), do: true
  defp class_reference?(_value), do: false

  defp ported?(python) do
    match?({:ok, %{status: :implemented}}, ModuleMap.resolve(python))
  end

  defp not_ported(elixir, status) do
    "#{elixir} is not built in this port (#{status}); the config names a class " <>
      "this port has no implementation for"
  end

  @doc """
  The dotted path inside a `${monty.class:...}` interpolation, or the value.

  Composition resolves interpolations, but a config may reach a builder before
  it has been through `Monty.Config.Resolvers` — a config written by hand in a
  test, for instance — so both forms are accepted.
  """
  @spec unwrap(String.t()) :: String.t()
  def unwrap("${monty.class:" <> rest), do: String.trim_trailing(rest, "}")

  def unwrap(dotted) do
    if Resolvers.unresolved?(dotted),
      do: raise(ArgumentError, "unresolved #{dotted}"),
      else: dotted
  end
end
