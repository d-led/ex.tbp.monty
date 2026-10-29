defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.SafeOperatingLimits do
  @moduledoc """
  The sigmas VOCUS2 was actually tried with, as fractions of the image.

  Mirrors
  `tbp/monty/frameworks/models/salience/strategies/vocus2/vocus2.py::SafeOperatingLimits`.

  A sigma is a distance in pixels, so what is a broad blur on a 64-pixel image
  is a tight one on a 128-pixel image. The limits are therefore fractions of the
  image's smallest dimension — `max_fractional_center_sigma: 0.1` on a 64-pixel
  image means a centre sigma of at most 6.4 — rather than absolute numbers that
  would only suit one resolution.

  Three rejections, in Monty's order: the surround must be meaningfully wider
  than the centre, the centre must sit inside its range, and the surround inside
  its own. Outside these limits VOCUS2 may work, may work differently, or may
  not work; the point of the check is that nobody finds out by accident.
  """

  @behaviour Monty.Frameworks.Models.Salience.Strategies.Vocus2.OperatingLimits

  @enforce_keys []
  defstruct min_image_dim_size: 64,
            max_fractional_center_sigma: 0.1,
            max_fractional_surround_sigma: 0.5,
            min_fractional_sigma_separation: 0.02

  @type t :: %__MODULE__{
          min_image_dim_size: pos_integer(),
          max_fractional_center_sigma: float(),
          max_fractional_surround_sigma: float(),
          min_fractional_sigma_separation: float()
        }

  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      min_image_dim_size: Keyword.get(options, :min_image_dim_size, 64),
      max_fractional_center_sigma: Keyword.get(options, :max_fractional_center_sigma, 0.1),
      max_fractional_surround_sigma: Keyword.get(options, :max_fractional_surround_sigma, 0.5),
      min_fractional_sigma_separation:
        Keyword.get(options, :min_fractional_sigma_separation, 0.02)
    }
  end

  @impl true
  @spec validate(t(), pos_integer(), float(), float()) ::
          :ok | Monty.Frameworks.Models.Salience.Strategies.Vocus2.OperatingLimits.rejection()
  def validate(%__MODULE__{} = limits, min_image_dim_size, center_sigma, surround_sigma) do
    fractional_center = center_sigma / min_image_dim_size
    fractional_surround = surround_sigma / min_image_dim_size

    cond do
      fractional_surround <
          fractional_center + limits.min_fractional_sigma_separation ->
        reject(
          "Surround sigma must be greater than or equal to center_sigma + " <>
            "min_fractional_sigma_separation."
        )

      not within?(
        center_sigma,
        min_image_dim_size * (1 / min_image_dim_size),
        min_image_dim_size * limits.max_fractional_center_sigma
      ) ->
        reject(
          "When smallest image dimension is #{min_image_dim_size}, " <>
            "Center sigma must be greater than or equal to " <>
            "#{min_image_dim_size * (1 / min_image_dim_size)} " <>
            "and less than or equal to " <>
            "#{min_image_dim_size * limits.max_fractional_center_sigma}. " <>
            "You provided #{center_sigma}."
        )

      not within?(
        surround_sigma,
        min_image_dim_size * (fractional_center + limits.min_fractional_sigma_separation),
        min_image_dim_size * limits.max_fractional_surround_sigma
      ) ->
        reject(
          "When smallest image dimension is #{min_image_dim_size}, " <>
            "Surround sigma must be greater than or equal to " <>
            "#{min_image_dim_size * (fractional_center + limits.min_fractional_sigma_separation)} " <>
            "and less than or equal to " <>
            "#{min_image_dim_size * limits.max_fractional_surround_sigma}. " <>
            "You provided #{surround_sigma}."
        )

      true ->
        :ok
    end
  end

  defp within?(value, low, high), do: low <= value and value <= high

  defp reject(message), do: {:error, message}
end
