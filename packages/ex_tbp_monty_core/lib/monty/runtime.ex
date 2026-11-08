defmodule Monty.Runtime do
  @moduledoc """
  What the runtime asks about a set of percepts.

  Mirrors `tbp/monty/runtime.py`, which is a module of small questions rather
  than a class — Monty puts them here so that every part of the system agrees on
  what a step contained. The processes that *run* a model live in
  `Monty.Runtime.*`; this module answers questions about the data they carry.
  """

  alias Monty.Cmp.Message

  @doc """
  Whether no sensor module percept carries features this step.

  Such a step is the sensor moving across the object without looking at it: the
  sensor's position changed, so every hypothesis must move with it, but nothing
  new was observed, so there is nothing to match or to learn. A learning module
  uses this to displace without updating evidence.

  A step with no sensor module percepts at all counts as location-only, because
  the question is "did any sensor bring something to match", and none did.

  Monty's `is_location_only_step`; `is_` is reserved for guards in Elixir, so
  the predicate ends in `?` instead.
  """
  @spec location_only_step?([Message.t()]) :: boolean()
  def location_only_step?(percepts) do
    percepts
    |> Enum.filter(&Message.from_sensor_module?/1)
    |> Enum.all?(&(not &1.process_features_in_lm))
  end
end
