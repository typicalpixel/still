defmodule Still.Agent.SystemInfo do
  @moduledoc """
  Static host facts an agent reports to the controller on connect —
  hostname, OS, CPU count, total RAM, free disk on the applications
  directory, and the agent's own version.

  Collected once per connect and persisted to `servers.metadata`. Anything
  volatile enough to need periodic sampling (CPU utilization, current free
  memory) belongs in the live-metrics path, not here.

  Linux only. Still doesn't target BSD/macOS/Windows, so `:memsup`
  and `:disksup` from `:os_mon` are assumed to work. The
  `/etc/os-release` read falls back to the raw `:os.type/0` tuple for
  minimal containers that omit it.
  """

  @doc """
  Collects the host fact map. Pass an explicit `applications_dir` from
  tests; production callers let it default to the configured setting.
  """
  def collect(applications_dir \\ Application.get_env(:still, :applications_dir)) do
    %{
      hostname: hostname(),
      os: os(),
      cpu_count: cpu_count(),
      memory_mb: memory_mb(),
      disk_free_mb: disk_free_mb(applications_dir),
      agent_version: agent_version()
    }
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  @doc """
  Prefer `PRETTY_NAME` from `/etc/os-release` (so operators see
  "Ubuntu 24.04.1 LTS"). Fall back to the `:os.type/0` tuple when the
  file is missing — minimal containers sometimes omit it. The path is
  configurable so tests can exercise the fallback branch.
  """
  def os(path \\ "/etc/os-release") do
    case File.read(path) do
      {:ok, contents} -> parse_pretty_name(contents) || os_fallback()
      _ -> os_fallback()
    end
  end

  @doc """
  Extracts the value of `PRETTY_NAME` from /etc/os-release contents.
  Returns `nil` if the field isn't present.
  """
  def parse_pretty_name(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        ["PRETTY_NAME", value] -> String.trim(value, ~s("))
        _ -> nil
      end
    end)
  end

  @doc """
  Best-effort OS string built from `:os.type/0`. Used when
  `/etc/os-release` isn't readable.
  """
  def os_fallback do
    {family, name} = :os.type()
    "#{family}/#{name}"
  end

  defp cpu_count, do: :erlang.system_info(:logical_processors_available)

  defp memory_mb do
    :memsup.get_system_memory_data()
    |> Keyword.fetch!(:system_total_memory)
    |> div(1_048_576)
  end

  defp disk_free_mb(nil), do: nil

  defp disk_free_mb(path) when is_binary(path) do
    disk_free_mb_from(:disksup.get_disk_data(), path)
  end

  @doc """
  Given a `:disksup.get_disk_data/0` return value and a target path,
  returns the free megabytes on the filesystem the path lives on, or
  `nil` if no mount matches.
  """
  def disk_free_mb_from(entries, path) when is_list(entries) and is_binary(path) do
    case best_mount_for(entries, path) do
      {_mount, total_kib, pct_used} ->
        free_kib = total_kib - div(total_kib * pct_used, 100)
        div(free_kib, 1024)

      _ ->
        nil
    end
  end

  # :disksup returns one entry per mount. Pick the longest prefix match of
  # the target path — that's the filesystem the applications dir actually
  # lives on, not `/` by default.
  defp best_mount_for(entries, path) do
    entries
    |> Enum.filter(fn {mount, _, _} -> String.starts_with?(path, to_string(mount)) end)
    |> Enum.max_by(fn {mount, _, _} -> String.length(to_string(mount)) end, fn -> nil end)
  end

  defp agent_version do
    {:ok, vsn} = :application.get_key(:still, :vsn)
    to_string(vsn)
  end
end
