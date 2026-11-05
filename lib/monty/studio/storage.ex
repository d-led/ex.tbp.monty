defmodule Monty.Studio.Storage do
  @moduledoc """
  How much room is left where this deployment writes.

  Two places matter, and they are not always one disk: what a run leaves behind
  (`Monty.Studio.Artifacts`) and what a prerequisite download adds
  (`Monty.Prerequisites`). In a container both are the one volume mounted under
  the application's home; in a checkout they are `priv/` and whatever `MONTY_DATA`
  and `MONTY_MODELS` name, which need not be the same disk.

  The number is the *device's*, as the operating system reports it, not this
  application's share of it. That is the honest answer to "is there room for
  another run": a quota, if one exists, is the deployment's business, and the
  device is the thing that fills.

  It is `os_mon`'s `disksup` that asks, and it answers with the whole of it: the
  mount point, the total, the space this user may still write and the percentage
  in use. On unix that is what `df` says, asked by OTP rather than parsed here;
  on Windows it is the drive table rather than nothing at all — this module used
  to run `df` itself, which is a program the platform this desktop app also
  ships to does not have.

  `device: nil` means the operating system would not say, which is a reason to
  show nothing rather than a zero that reads as a full disk.
  """

  @typedoc """
  The disk a path sits on, as `disksup` reports it.

  `mount` is the name the operating system gives it — `/` or
  `/System/Volumes/Data` on unix, `C:\` on Windows — and is what tells two
  paths whether they are one disk.

  `free_bytes` is what this user may still write, and `percent` is used as the
  operating system computes it: of the whole disk, not of what is left to this
  application.
  """
  @type device :: %{
          required(:mount) => Path.t(),
          required(:total_bytes) => non_neg_integer(),
          required(:free_bytes) => non_neg_integer(),
          required(:percent) => non_neg_integer()
        }

  @typedoc """
  A place this deployment writes, and the room left on its volume.

  `path` is the place that was asked about; `device` describes the volume that
  answered for it.
  """
  @type usage :: %{required(:path) => Path.t(), required(:device) => device() | nil}

  @doc """
  The room left on the volume that holds `path`.

  `path` need not exist yet — a download directory is created by the download —
  so a missing directory is measured on the nearest one that is there.
  """
  @spec usage(Path.t()) :: usage()
  def usage(path) do
    expanded = Path.expand(path)

    %{path: expanded, device: device(nearest_existing(expanded))}
  end

  # `disksup` answers `{mount point, total KiB, available KiB, percent used}` for
  # the disk that holds the path it is given, and `{path, 0, 0, 0}` when it
  # cannot say: a path that does not exist, a disk it does not list, or an
  # `os_mon` that is not running (which it logs rather than raises).
  #
  # On unix `disksup` builds a `df` command line with this path on it and runs it
  # through its own port program, so a path is a path and not an argument. That
  # is also why nothing here may pass a caller's path through: the two places are
  # the artifact root from the application's config and the download root from
  # Monty's own environment variables.
  defp device(path) do
    case path |> disk_argument() |> :disksup.get_disk_info() |> List.first() do
      {mount, total, free, percent} when total > 0 ->
        %{
          mount: to_string(mount),
          total_bytes: kibibytes(total),
          free_bytes: kibibytes(free),
          percent: percent
        }

      _would_not_say ->
        nil
    end
  end

  # On Windows the argument is the drive root — `C:\` — because that is what the
  # drive table is keyed by; on unix it is the path itself, which `df` resolves
  # to a mount point.
  defp disk_argument(path) do
    case :os.type() do
      {:win32, _} -> path |> Path.split() |> hd()
      _ -> path
    end
  end

  # `df` wants a path that exists; before the first run there is no artifacts
  # directory, and the disk is still there one level up.
  defp nearest_existing(path) do
    if File.exists?(path) or Path.dirname(path) == path do
      path
    else
      path |> Path.dirname() |> nearest_existing()
    end
  end

  # `disksup` counts in kibibytes.
  defp kibibytes(kibibytes), do: kibibytes * 1024
end
