defmodule ExTbpMonty.MatcherNif do
  @moduledoc """
  The native kernels a matching step repeats once per node.

  The Elixir arithmetic in each calling module is the reference: it is what the
  tests describe, what runs on a machine without a Rust toolchain, and what these
  kernels are held to by parity tests. They exist because that reference pays
  Elixir's price per value — a boxed float, a list cell, a tuple — where the
  answer is the same arithmetic over a few thousand rows.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a
  caller asks once, and every caller has a path for the answer `false`.
  """

  use Rustler, otp_app: :ex_tbp_monty, crate: "matcher_nif"

  @doc """
  Whether this VM built and loaded the native kernels.

  Asked on a path that runs once per step per graph, so the answer is remembered:
  a NIF that is loaded stays loaded, and one that is not stays absent.
  """
  @spec loaded?() :: boolean()
  def loaded? do
    case :persistent_term.get({__MODULE__, :loaded}, :unknown) do
      :unknown ->
        answer = loaded_now?()
        :persistent_term.put({__MODULE__, :loaded}, answer)
        answer

      answer ->
        answer
    end
  end

  defp loaded_now? do
    available()
  rescue
    # A NIF that is not loaded answers every call with this raise, which is how
    # the runtime says "not here" rather than an error value.
    ErlangError -> false
  end

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The feature evidence of every row, computed natively.

  `rows` is `n * width` little-endian f64 with NaN where a node has no value;
  `specs` gives each column's index and kind (two u32), `params` its observed
  value, tolerance and weight (three f64). The answer is `n` f64, NaN where the
  reference answers `nil`.
  """
  def feature_evidence(_rows, _width, _specs, _params, _increment),
    do: :erlang.nif_error(:nif_not_loaded)
end
