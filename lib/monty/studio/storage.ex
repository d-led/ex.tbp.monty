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

  Each platform is asked the way that platform can answer:

  * **unix** — `df -kP <path>`, with the path as an *argument* and not as a
    command line, so a directory called `Application Support` is one argument.
    `df` is also the only thing that can say which volume a path is on: on macOS
    everything under `/Users` lives on `/System/Volumes/Data`, reached through a
    firmlink that reports the same device number as `/`, so comparing mount
    points or device numbers cannot tell the two apart — `df`'s own resolution
    of the path can.
  * **Windows** — there is no `df`. `os_mon`'s `disksup` holds the drive table,
    `{drive root, total, free, capacity}` per fixed disk, and the path is matched
    to its drive there.

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

  # The path is expanded, so a caller's `priv` and the drive root it lands on are
  # compared as absolute paths.
  defp device(path) do
    case :os.type() do
      {:win32, _} -> windows_volume(path, disks())
      _ -> unix_volume(path)
    end
  end

  # `df -P` is the portable spelling: POSIX output, one line per filesystem, a
  # path in and the filesystem out, with the mount point last so it may be
  # joined back together when it holds a space.
  defp unix_volume(path) do
    with {out, 0} <- System.cmd("df", ["-kP", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [_filesystem, total, _used, free, capacity | mount] <- String.split(line) do
      %{
        mount: Enum.join(mount, " "),
        total_bytes: blocks(total),
        free_bytes: blocks(free),
        percent: capacity |> String.trim_trailing("%") |> String.to_integer()
      }
    else
      _would_not_say -> nil
    end
  end

  @doc """
  The drive that holds `path`, out of the drives `disksup` lists.

  `volumes` is `disksup`'s shape — `{drive root, total KiB, free KiB, percent
  used}` per fixed disk — which is why this is public: it is the one half of this
  module that cannot run on a machine without drives.
  """
  @spec windows_volume(Path.t(), [{charlist(), integer(), integer(), integer()}]) ::
          device() | nil
  def windows_volume(path, volumes) do
    case drive_of(path) do
      nil ->
        nil

      drive ->
        volumes
        |> Enum.find(fn {root, _, _, _} ->
          root |> to_string() |> String.downcase() |> String.starts_with?(drive)
        end)
        |> volume()
    end
  end

  # `C:\Users\…` is on `C:`, whatever the separator. A UNC path — `\\server\share`
  # — names no drive, and the drive table does not list one, so there is nothing
  # to match it against.
  defp drive_of(<<letter, ?:, _::binary>>) when letter in ?a..?z or letter in ?A..?Z,
    do: String.downcase(<<letter, ?:>>)

  defp drive_of(_path), do: nil

  defp volume({mount, total, free, percent}) when total > 0 do
    %{
      mount: to_string(mount),
      total_bytes: kibibytes(total),
      free_bytes: kibibytes(free),
      percent: percent
    }
  end

  defp volume(_would_not_say), do: nil

  # `disksup` lists every fixed disk it knows; `[{~c"none", 0, 0, 0}]` when
  # `os_mon` is not running, which is a reason to answer nothing rather than to
  # log a warning per call.
  defp disks do
    if Process.whereis(:disksup), do: :disksup.get_disk_info(), else: []
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

  # `df -k` counts in 1024-byte blocks whatever the filesystem's own block size.
  defp blocks(kilobytes), do: String.to_integer(kilobytes) * 1024

  # `disksup` counts in kibibytes.
  defp kibibytes(kibibytes), do: kibibytes * 1024
end
