defmodule Monty.Frameworks.Models.ObjectModel.GridTooSmallError do
  @moduledoc """
  An object does not fit in the space the model was given to represent it.

  Mirrors `tbp/monty/frameworks/models/object_model.py::GridTooSmallError`,
  raised when too many of an episode's observations fall outside the model's
  grid. Monty only accepts an update in which at least 90% of the observations
  land inside; below that, the object is larger than `max_size`, and storing it
  would silently store a corner of it.

  The fraction that did fit is carried along, because "70% of what I saw fits"
  is the number an experiment needs to know whether to model bigger objects.
  """

  defexception [:fraction_in_bounds]

  @type t :: %__MODULE__{fraction_in_bounds: float() | nil}

  @impl true
  def message(%{fraction_in_bounds: nil}) do
    "too many observations fall outside the model's grid"
  end

  def message(%{fraction_in_bounds: fraction}) do
    "only #{Float.round(fraction * 100, 2)}% of the observations fall inside " <>
      "the model's grid; the object is larger than the model can represent"
  end
end
