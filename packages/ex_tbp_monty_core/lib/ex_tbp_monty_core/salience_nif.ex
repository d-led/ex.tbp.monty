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
  sRGB to the Lab `skimage` answers: three planes out of one interleaved binary.

  The reference is `Images.rgb_to_lab/1` followed by `SlicMerge.skimage_lab/1` —
  the rescale `(value - low) / span * 255.0`, the gamma decode, OpenCV's D65
  matrix, its white point, the 8-bit scaling with its clamps, and the `L * 100`,
  `a * 255 - 128`, `b * 255 - 128` the wrapper reads back.

  `rgb` is `count` pixels of three little-endian `f64`s; the answer is three
  planes of `count` values, `L` then `a` then `b`.
  """
  def lab(_rgb, _count, _low, _span), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The same conversion in OpenCV's own scaling — `L / 100`, `(a + 128) / 255`,
  `(b + 128) / 255` — which is what `Images.rgb_to_lab/1` answers and what the
  superpixel mean colours are taken in.
  """
  def lab_opencv(_rgb, _count, _low, _span), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The feature maps combined by their weights and normalised to `[0, 1]`.

  `maps` is the planes concatenated as little-endian `f64` values, `weights` one
  per map in the same order, and the answer is `width * height` values — the
  weighted mean summed in that order, then `Vocus2.range_normalize/1`'s
  `(value - low) / range` or its clip when the range is below `1.0e-8`.
  """
  def combine_weighted(_maps, _weights, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  One colour channel's salience map, from the plane to the collapsed map.

  Everything `ColorChannelSalience.reference/3` does — the centre and surround
  pyramids, their difference, `brighter`/`darker` and their mean, and the
  collapse — over one binary. `shapes` is one `{width, height}` pair of
  little-endian `u32`s per octave, finest first; `scale_sigmas` is the sigma each
  further scale is blurred by and `surround_sigmas` the sigma each surround is
  blurred by, both little-endian `f64`. Every scalar is resolved on the Elixir
  side, so no power or square root happens here.

  Answers `{map, centres, centre_shapes}`: the map at the finest octave's shape,
  the centre pyramid's planes concatenated, and one shape pair per centre plane.
  """
  def channel_salience(
        _plane,
        _shapes,
        _first_sigma,
        _scale_sigmas,
        _surround_sigmas,
        _truncate
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  A pyramid collapsed into one plane: every plane enlarged to `width` by
  `height` with the cubic, then averaged pixel by pixel in plane order, exactly
  as `Pyramids.collapse_mean_reference/1` reduces it.

  `planes` is the concatenation of the pyramid's planes as little-endian `f64`
  values, `shapes` one `{width, height}` pair of little-endian `u32`s per plane
  in the same order, and the answer is `width * height` values.
  """
  def collapse_mean(_planes, _shapes, _width, _height),
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
