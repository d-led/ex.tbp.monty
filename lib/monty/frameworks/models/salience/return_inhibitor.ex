defmodule Monty.Frameworks.Models.Salience.ReturnInhibitor do
  @moduledoc """
  Inhibition of return: do not propose the place you just looked at.

  Mirrors `tbp/monty/frameworks/models/salience/return_inhibitor.py::ReturnInhibitor`.
  A salience module's goals are where to look next, and without this it would keep
  proposing the most interesting pixel of the last view — which is the one place it
  has already seen. Each call records where the sensor was, weighs every candidate
  location against every visit, and then ages the visits by a step.

  Monty mutates the field; a struct here is a value, so a call answers both the
  weights and the inhibitor that produced them.
  """

  alias Monty.Frameworks.Models.Salience.ReturnInhibitor.DecayField

  defstruct decay_field: nil

  @type t :: %__MODULE__{decay_field: DecayField.t()}

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{decay_field: Keyword.get_lazy(options, :decay_field, &DecayField.new/0)}
  end

  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = inhibitor) do
    %__MODULE__{inhibitor | decay_field: DecayField.reset(inhibitor.decay_field)}
  end

  @doc """
  How much each of `query_locations` is inhibited, having just looked from
  `visited_location` (`nil` when the middle of the view was not on an object).
  """
  @spec call(t(), [float()] | nil, [[float()]]) :: {[float()], t()}
  def call(%__MODULE__{} = inhibitor, visited_location, query_locations) do
    field =
      case visited_location do
        nil -> inhibitor.decay_field
        location -> DecayField.add(inhibitor.decay_field, location)
      end

    weights = DecayField.weights(field, query_locations)

    {weights, %__MODULE__{inhibitor | decay_field: DecayField.step(field)}}
  end
end
