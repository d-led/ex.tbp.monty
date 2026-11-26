defmodule ExTbpMonty.Core.SalienceNif do
  @moduledoc """
  The native kernels the salience strategies use when they can: the bicubic
  resize, the Gaussian blur, SLIC's whole label field, the mean colour of every
  superpixel, and the Vocus2 channel arithmetic.

  A pyramid's collapse resamples every octave back to the view's size, and each
  pixel is sixteen taps: 16.8 million of them in a 256-square salience step, at
  the BEAM's ~20 million operations a second. A boundary costs a crossing —
  encode, call, decode — and on a view this size a crossing is often the larger
  half: three 256-square blurs measured 29.15 ms through their own crossings
  against 0.96 ms of taps. So a kernel is one of Monty's own calls wherever
  Monty makes one: `slic/3` is `skimage.segmentation.slic`, `region_colours/4`
  is `extract_region_colors`, and each keeps its Elixir reference.

  A NIF is a library the BEAM loads into itself, so its absence is a raised
  `ErlangError` rather than a returned error: `loaded?/0` is the question a caller
  asks once, and each caller asks it per call.

  A plane crosses as one binary of little-endian `f64` values, row-major,
  because a 256-square view is 65 536 numbers and encoding them as lists twice
  would cost more than the arithmetic.
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
  The mean colour of every superpixel, in the scale Monty's merge threshold is a
  threshold in: `cv2.cvtColor(image, COLOR_RGB2LAB) / 255`, averaged per region.

  `SlicMerge.compute_superpixel_mean_colors/2` is the reference — the sum in
  raster order, per region, and the zeros the reference leaves for a region the
  labels never name. `rgb` is `width * height` pixels of three little-endian
  `f64`s; `labels` is one little-endian `u32` per pixel; the answer is three
  `f64` per region, `region_max + 1` regions, in label order.
  """
  def region_colours(_rgb, _labels, _width, _height), do: :erlang.nif_error(:nif_not_loaded)

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
  `skimage.segmentation.slic` — the view's label field, which is one call in
  Monty's `slic_merge.py`.

  Inside that one call `skimage` rescales the colours to fill their own range,
  converts to Lab, blurs with `sigma`, runs the k-means in Lab-plus-position
  space and enforces connectivity; every one of those steps had a kernel of its
  own here, and each crossing between two of them cost more than the arithmetic
  it carried. This is the same chain in one crossing and the same numbers:
  `SlicMerge.segment_image_reference/2` is the reference and a parity case holds
  the two label fields to each other.

  `rgb` is `width * height` pixels of three little-endian `f64`s, the camera's
  values; `seeds` is five `f64` each — `y`, `x`, `r`, `g`, `b`; `settings`
  carries Monty's SLIC parameters (`compactness`, `max_iter`, `sigma`,
  `min_size`, `max_size`, the grid's `step_y`/`step_x` and `spatial_factor`) and
  the shape. The answer is one little-endian `u32` per pixel.
  """
  def slic(_rgb, _seeds, _settings), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  How strongly every visit argues against every point — Monty's `np.max` over the
  field's kernels.

  `kernels` is six little-endian `f64` each — the place it was made (`x`, `y`,
  `z`), its weight from age alone, the distance at which it halves, and its
  spatial cutoff (`+inf` for a kernel that has none); `points` is three `f64`
  each; the answer is `count` weights, the strongest kernel at each point.

  `DecayField.weights_reference/2` is the reference the answer is held to.
  """
  def inhibition_weights(_kernels, _points, _count), do: :erlang.nif_error(:nif_not_loaded)
end
