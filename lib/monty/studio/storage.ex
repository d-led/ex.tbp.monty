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

  The question is put to `os_mon`'s `disksup`, which asks the operating system
  the way that system can answer — `df -kP <path>` on unix, the drive's own
  geometry on Windows — and which therefore resolves a path to a volume the way
  the operating system does. On macOS that resolution is the only one that works:
  everything under `/Users` lives on `/System/Volumes/Data`, reached through a
  firmlink that reports the same device number as `/`, so comparing mount points
  or device numbers cannot tell the two apart — `df`'s own resolution of the path
  can.

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

    # A path that does not exist yet is still on a disk: the table of mounts
    # answers for it by name alone.
    %{path: expanded, device: device(expanded)}
  end

  @doc """
  The path `disksup` is asked about, to learn where `path` writes.

  Windows' drive table is keyed by drive root, so `C:\\Users\\…` is asked about as
  `C:\\`; unix's `df` takes the path itself and resolves the volume from it. A
  path that is not there yet is asked about as the nearest directory that is:
  `df` cannot stat a directory that does not exist, and the disk it would go on
  is the disk of the one above it.

  Public because it is the half of this module the other kind of machine cannot
  exercise — a unix box has no drives to name, a Windows box has no `df`.
  """
  @spec probe(Path.t()) :: Path.t()
  def probe(path) do
    case drive_root(path) do
      nil -> nearest_existing(path)
      root -> root
    end
  end

  # `C:\\Users\\…` is on `C:\\`, whatever the separator or the letter's case. A UNC
  # path — `\\\\server\\share` — names no drive, and there is no root to name.
  defp drive_root(<<letter, ?:, _::binary>>) when letter in ?a..?z or letter in ?A..?Z,
    do: String.upcase(<<letter>>) <> ":\\"

  defp drive_root(_path), do: nil

  # `df` fails on a directory that does not exist yet. Before the first run there
  # is no artifacts directory, and the disk is still there one level up.
  defp nearest_existing(path) do
    if File.exists?(path) or Path.dirname(path) == path do
      path
    else
      path |> Path.dirname() |> nearest_existing()
    end
  end

  # `disksup` answers `{mount, total KiB, free KiB, percent used}` for the volume
  # a path is on, read from the operating system when it is called rather than
  # from a cached table, so a disk that filled a minute ago is reported full.
  defp device(path) do
    asked = probe(path)

    :disksup.get_disk_info(asked)
    |> Enum.find(&answers_for?(&1, drive_root(asked)))
    |> volume()
  catch
    # `os_mon` is not running, or the machine would not say: show nothing rather
    # than a zero that reads as a full disk.
    _kind, _reason -> nil
  end

  # A path is answered for and the volume is taken as named: `df` names it the
  # way the operating system mounts it, and on macOS `/Users/…` is answered by
  # `/System/Volumes/Data`, whose name is not a prefix of the path. A drive is
  # matched by name, because the table of drives can come back whole.
  defp answers_for?({_mount, total, _free, _percent}, nil), do: total > 0

  defp answers_for?({mount, total, _free, _percent}, drive),
    do: total > 0 and String.starts_with?(String.upcase(to_string(mount)), drive)

  defp volume({mount, total, free, _percent}) when total > 0 do
    %{
      mount: to_string(mount),
      total_bytes: kibibytes(total),
      free_bytes: kibibytes(free),
      # Of the disk, as the operating system computes it: the table's own figure
      # is the volume's, and the volume is not always the one the path is on.
      percent: percent_used(total, free)
    }
  end

  defp volume(_would_not_say), do: nil

  defp percent_used(total, free) when total > 0 do
    used = max(total - min(free, total), 0)
    round(used * 100 / total)
  end

  # `disksup` counts in kibibytes.
  defp kibibytes(kibibytes), do: kibibytes * 1024
end
