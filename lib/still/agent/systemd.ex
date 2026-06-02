defmodule Still.Agent.Systemd do
  @moduledoc """
  Read-only queries about what systemd is currently doing with an
  application slot. Surfaces the pid, the unit's active state, and the
  timestamp it entered that state — the fields the dashboard shows
  under each app on a server.

  The systemctl shellout is the only side-effecting part; the parser is
  pure and unit-tested. When systemd isn't reachable (agent running
  outside a real host, or the unit doesn't exist yet) every field is
  `nil` so the report round-trips without errors.
  """

  @properties ~w(MainPID ActiveState ActiveEnterTimestamp)
  @empty %{pid: nil, active_state: nil, active_enter_at: nil}

  @doc """
  Returns `{pid, active_state, active_enter_at}` for an application slot,
  as a map. All fields are `nil` when the unit isn't present or
  `systemctl` can't be called.
  """
  def info_for(_application_name, nil), do: @empty

  # six:ignore:start
  # Thin System.cmd wrapper — exercised through the real systemd path in
  # deploy integration tests, not via unit mocks.
  def info_for(application_name, slot)
      when is_binary(application_name) and slot in [:blue, :green, "blue", "green"] do
    instance = "#{application_name}@#{slot}"

    case systemctl_show(instance) do
      {:ok, output} -> parse(output)
      :error -> @empty
    end
  end

  # six:ignore:stop

  @doc """
  Parses the key/value output of `systemctl show <unit> --property=...`.
  Pure function — shape matters on the systemd side but the parser has
  no external dependencies.
  """
  def parse(output) when is_binary(output) do
    fields =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    %{
      pid: parse_pid(fields["MainPID"]),
      active_state: parse_active_state(fields["ActiveState"]),
      active_enter_at: parse_active_enter(fields["ActiveEnterTimestamp"])
    }
  end

  # systemctl reports MainPID=0 for units that aren't running — surface
  # that as nil rather than the literal 0 so the dashboard can treat
  # "no pid" uniformly.
  defp parse_pid(nil), do: nil
  defp parse_pid(""), do: nil

  defp parse_pid(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {0, _} -> nil
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_active_state(nil), do: nil
  defp parse_active_state(""), do: nil
  defp parse_active_state(raw) when is_binary(raw), do: raw

  # systemctl emits timestamps like "Thu 2026-04-20 15:00:00 UTC" or an
  # empty string before the unit has ever run. Unless we can parse it,
  # return nil — the wire shape is explicit about missing values.
  defp parse_active_enter(nil), do: nil
  defp parse_active_enter(""), do: nil

  defp parse_active_enter(raw) when is_binary(raw) do
    case Regex.run(~r/(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) UTC/, raw) do
      [_, date, time] ->
        case DateTime.from_iso8601("#{date}T#{time}Z") do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # six:ignore:start
  defp systemctl_show(instance) do
    args = ["show", instance, "--property", Enum.join(@properties, ",")]

    case System.cmd("systemctl", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  # six:ignore:stop
end
