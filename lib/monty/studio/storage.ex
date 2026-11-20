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
  the way that system can answer — `df -k` on unix, the drive's own geometry on
  Windows — and which therefore names volumes the way the operating system mounts
  them. On macOS that name is not a prefix of the path: everything under `/Users`
  lives on `/System/Volumes/Data`, reached through a firmlink, so the volume is
  chosen by the longest mount that holds the path rather than by comparing mount
  points or device numbers.

  `disksup`'s *path* answer is not used: on unix it passes the path to `df`
  unquoted, so a directory with a space in it — `Monty on the BEAM.app` is the
  one that shipped — makes `df` fail and the answer come back as zeros. The mount
  table cannot fail that way, and the volume that holds the longest mount holding
  the path is the one `df` would have resolved.

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
  because the question is which volume it would be written to, and the mount
  table answers that by name alone.
  """
  @spec usage(Path.t()) :: usage()
  def usage(path) do
    expanded = Path.expand(path)

    # A path that does not exist yet is still on a disk, and the table of mounts
    # names the disk by where it is mounted rather than by what is in it.
    %{path: expanded, device: device(expanded)}
  end

  @doc """
  The volume a path sits on, out of the operating system's mount table.

  `nil` when the table holds nothing that could hold the path — a network volume
  is not in it — and nothing is said rather than someone else's disk.

  Public because it is the half of this module the other kind of machine cannot
  exercise: a unix box has no drives to name by letter, a Windows box has no
  mounts to match by path.
  """
  @spec volume_for([tuple()], Path.t()) :: tuple() | nil
  def volume_for(table, path) do
    case drive_root(path) do
      nil -> by_longest_mount(table, path)
      drive -> Enum.find(table, &on_drive?(&1, drive))
    end
  end

  # The volume that holds the most of the path, which is the one it writes to.
  # The match is on path segments: `/System/Volumes/Data2` is not inside
  # `/System/Volumes/Data`.
  defp by_longest_mount(table, path) do
    table
    |> Enum.filter(fn {mount, _total, _free, _percent} -> holds?(to_string(mount), path) end)
    |> Enum.max_by(
      fn {mount, _total, _free, _percent} -> byte_size(to_string(mount)) end,
      fn -> nil end
    )
  end

  defp holds?(mount, path) do
    # The root mount is `/`, which is the empty prefix of every path.
    mount = String.trim_trailing(mount, "/")
    path == mount or String.starts_with?(path, mount <> "/")
  end

  # A drive is matched by its letter: the table names drives `C:\` and a path
  # names them the same way, and nothing else in a Windows path identifies a
  # volume.
  defp on_drive?({mount, _total, _free, _percent}, <<letter, ?:>> <> _rest) do
    letter = String.upcase(<<letter>>)
    String.starts_with?(String.upcase(to_string(mount)), letter <> ":")
  end

  defp on_drive?(_row, _drive), do: false

  # `C:\\Users\\…` is on `C:\\`, whatever the separator or the letter's case. A UNC
  # path — `\\\\server\\share` — names no drive, and there is no root to name.
  defp drive_root(<<letter, ?:, _::binary>>) when letter in ?a..?z or letter in ?A..?Z,
    do: String.upcase(<<letter>>) <> ":\\"

  defp drive_root(_path), do: nil

  # The table is read when it is asked for rather than from a cache: `disksup`
  # polls it on its own interval, and a disk that filled a minute ago is reported
  # full.
  defp device(path) do
    :disksup.get_disk_info()
    |> volume_for(path)
    |> volume()
  catch
    # `os_mon` is not running, or the machine would not say: show nothing rather
    # than a zero that reads as a full disk.
    _kind, _reason -> nil
  end

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
