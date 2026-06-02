defmodule StillWeb.HookJSON do
  @moduledoc """
  JSON serialization for lifecycle-hook endpoints.
  """

  alias Still.Applications.Hook

  @doc "Renders a list of hooks for the index endpoint."
  def render(hooks) when is_list(hooks) do
    %{data: Enum.map(hooks, &hook/1)}
  end

  @doc "Renders a single hook for create/update."
  def render_one(%Hook{} = hook) do
    %{data: hook(hook)}
  end

  @doc "Base shape for a hook row."
  def hook(%Hook{} = hook) do
    %{
      id: hook.id,
      application_id: hook.application_id,
      event: hook.event,
      script: hook.script,
      timeout_ms: hook.timeout_ms,
      inserted_at: hook.inserted_at,
      updated_at: hook.updated_at
    }
  end
end
