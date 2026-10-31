defmodule Monty.Studio.Storage do
  @moduledoc """
  How much room is left where this deployment writes.

  Two places matter, and they are not always one disk: what a run leaves behind
  (`Monty.Studio.Artifacts`) and what a prerequisite download adds
  (`Monty.Prerequisites`). In the container they are the same volume, mounted at
  `/app/priv`; in a checkout they are `priv/` and `~/tbp`.

  The number is the *device's*, as the operating system reports it — `df -kP` for
  the filesystem the path sits on — not this application's share of it. That is
  the honest answer to "is there room for another run": a quota, if one exists,
  is the deployment's business, and the device is the thing that fills.

  `device: nil` means the operating system would not say, which is a reason to
  show nothing rather than a zero that reads as a full disk.
  """

  @typedoc """
  The device a path sits on, as `df` reports it.

  `percent` is used, as `df` computes it — of the whole device, not of what is
  left to this application.
  """
  @type device :: %{
          required(:filesystem) => String.t(),
          required(:mount) => String.t(),
          required(:total_bytes) => non_neg_integer(),
          required(:used_bytes) => non_neg_integer(),
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

  # `df -P` is the portable spelling: POSIX output, one line per filesystem,
  # a path in and the filesystem out, with the mount point last so it may be
  # joined back together when it holds a space.
  #
  # The command is `df`, with the path this module was given and no shell.
  # Nothing on `/mcp` passes a path through: the two places are the artifact
  # root from the application's config and the download root from Monty's own
  # environment variables. Asking the operating system is how the free space is
  # read rather than assumed.
  defp device(path) do
    with {out, 0} <- System.cmd("df", ["-kP", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(out, "\n", trim: true),
         [filesystem, total, used, free, capacity | mount] <- String.split(line) do
      %{
        filesystem: filesystem,
        mount: Enum.join(mount, " "),
        total_bytes: blocks(total),
        used_bytes: blocks(used),
        free_bytes: blocks(free),
        percent: capacity |> String.trim_trailing("%") |> String.to_integer()
      }
    else
      _would_not_say -> nil
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

  # `df -k` counts in 1024-byte blocks whatever the filesystem's own block size.
  defp blocks(kilobytes), do: String.to_integer(kilobytes) * 1024
end
