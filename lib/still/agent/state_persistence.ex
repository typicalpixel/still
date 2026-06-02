defmodule Still.Agent.StatePersistence do
  @moduledoc """
  Reads and writes per-application `state.json` files on the agent's filesystem.

  Each managed application has its own state file at
  `<applications_dir>/<application_name>/state.json`. Writes are atomic — the
  new contents go to a `.tmp` file first and are then renamed into place — so
  a partial write cannot leave the file corrupted.
  """

  alias Still.Agent.ApplicationState

  @doc """
  Reads the persisted state for the given application.

  Returns `{:ok, %ApplicationState{}}`, `{:error, :not_found}` if no state
  file exists yet, or `{:error, :corrupted}` if the file cannot be parsed.
  """
  def read(application_name) when is_binary(application_name) do
    case File.read(state_file_path(application_name)) do
      {:ok, json} -> decode(json)
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Atomically writes the persisted state for the given application.

  Creates the application directory if it does not yet exist. Returns `:ok`
  or `{:error, reason}` from the underlying file operations.
  """
  def write(application_name, %ApplicationState{} = state)
      when is_binary(application_name) do
    path = state_file_path(application_name)
    tmp_path = path <> ".tmp"

    File.mkdir_p!(Path.dirname(path))

    case File.write(tmp_path, Jason.encode!(state)) do
      :ok -> File.rename(tmp_path, path)
      error -> error
    end
  end

  @doc """
  Lists the names of all applications that have a `state.json` on disk.

  Used by the agent on boot to discover which applications it manages.
  """
  def list_applications do
    base = applications_dir()

    case File.ls(base) do
      {:ok, entries} ->
        Enum.filter(entries, fn name ->
          File.exists?(Path.join([base, name, "state.json"]))
        end)

      {:error, :enoent} ->
        []
    end
  end

  @doc """
  Deletes the state file for the given application. Treats "already gone"
  as success.
  """
  def delete(application_name) when is_binary(application_name) do
    case File.rm(state_file_path(application_name)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  defp state_file_path(application_name) do
    Path.join([applications_dir(), application_name, "state.json"])
  end

  defp applications_dir do
    Application.fetch_env!(:still, :applications_dir)
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, build_state(map)}
      {:error, _} -> {:error, :corrupted}
    end
  end

  defp build_state(map) do
    %ApplicationState{
      type: map["type"],
      active_slot: map["active_slot"],
      active_port: map["active_port"],
      current_version: map["current_version"],
      previous_version: map["previous_version"],
      last_health_check_at: map["last_health_check_at"]
    }
  end
end
