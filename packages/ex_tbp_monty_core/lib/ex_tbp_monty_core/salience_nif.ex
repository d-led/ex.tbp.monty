defmodule ExTbpMonty.Core.SalienceNif do
  @moduledoc """
  The native kernels `Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images`
  and `SlicMerge` use when they can: the bicubic resize, SLIC's k-means, and the
  Gaussian blur.

  A pyramid's collapse resamples every octave back to the view's size, and each
  pixel is sixteen taps: 16.8 million of them in a 256-square salience step, at
  the BEAM's ~20 million operations a second. The Elixir implementation in
  `Images.cubic_reference/3` is the reference — what the tests describe, what
  runs where no Rust toolchain built this — and this is the fast path, held to it
  by a parity test.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a caller
  asks once, and `Images.resize/3` asks it per call.

  The plane crosses as one binary of little-endian `f64` values, row-major,
  because a 256-square view is 65 536 numbers and encoding them as lists twice
  would cost more than the resize.
  """

  use Rustler, otp_app: :ex_tbp_monty_core, crate: "salience_nif"

  @doc "Whether this VM built and loaded the native resize."
  @spec loaded?() :: boolean()
  def loaded? do
    available()
  rescue
    # A NIF that is not loaded answers every call with this raise, which is how
    # the runtime says "not here" rather than an error value.
    ErlangError -> false
  end

  @doc "True, from the native side — the only way to know it is loaded."
  def available, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A `width` by `height` plane resampled from `source`, OpenCV's cubic (`A =
  -0.75`) with the edge pixel repeated, exactly as `Images.cubic_reference/3`
  computes it.

  `source` is `source_width * source_height` little-endian `f64` values,
  row-major. The answer is the same encoding, row-major, `width * height` values.
  """
  def enlarge_cubic(_source, _source_width, _source_height, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A `width` by `height` plane blurred with a Gaussian of `sigma`, exactly as
  `Images.gaussian_blur_reference/3` computes it.

  The kernel is Monty's — `round(2 * truncate * sigma + 1)`, forced odd — and the
  two passes are OpenCV's: across each row, then down each column, the edge pixel
  repeated outward. `plane` is `width * height` little-endian `f64` values,
  row-major, and the answer is the same encoding.
  """
  def blur(_plane, _width, _height, _sigma, _truncate),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  SLIC's connectivity pass: every label becomes one connected blob, and a blob
  smaller than `min_size` is absorbed into the label it borders, exactly as
  `SlicMerge.enforce_connectivity_reference/4` walks it.

  `labels` is `width * height` little-endian `u32` labels, row-major; the answer
  is the same encoding.
  """
  def enforce_connectivity(_labels, _width, _height, _min_size, _max_size),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  SLIC's k-means: one label per pixel, as the `SlicMerge` reference computes it.

  `pixels` is `width * height` colours of three little-endian `f64`s, already
  scaled by `1/compactness`; `seeds` is five `f64` each — `y`, `x`, `r`, `g`,
  `b`. `step_y`/`step_x` are the seed grid's steps, truncated as the window uses
  them, and `spatial_factor` is `1 / max(steps)²`.

  The answer is `width * height` little-endian `u32` labels.
  """
  def slic_labels(_pixels, _width, _seeds, _step_y, _step_x, _spatial_factor, _max_iter),
    do: :erlang.nif_error(:nif_not_loaded)
end
