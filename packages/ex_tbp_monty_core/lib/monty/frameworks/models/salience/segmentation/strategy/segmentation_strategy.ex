defmodule Monty.Frameworks.Models.Salience.Segmentation.Strategy.SegmentationStrategy do
  @moduledoc """
  How a salience module turns a colour image into one region.

  Mirrors
  `tbp/monty/frameworks/models/salience/segmentation/strategy.py::SegmentationStrategy`,
  a `Protocol` in Monty: a segmentation answers a mask saying which pixels belong
  to the region a salience module should attend to.

  Monty's own implementation, `SlicMerge`, is still to come; a module configured
  without one proposes no region, which is a module that only proposes goals.
  """

  @type t :: struct()

  @doc "A segmentation mask for `rgb`, one number per pixel."
  @callback call(t(), Monty.Context.t(), [[[float()]]]) :: [[number()]]
end
