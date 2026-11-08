defmodule Monty.Frameworks.Models.Salience.Strategies.Protocol do
  @moduledoc """
  How a salience module decides where in a view is worth looking.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/protocol.py`, whose one
  class is `SalienceStrategy`
  (`...Strategies.Protocol.SalienceStrategy`): Monty declares it as a `Protocol`
  so a config can name any callable. It is a behaviour here, and a strategy
  answers a salience map of the same shape as the depth image — one number per
  pixel saying how interesting that pixel is.
  """
end
