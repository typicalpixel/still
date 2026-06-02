defmodule StillWeb.DeploymentJSON do
  @moduledoc """
  JSON serialization for the deployment API. Three public shapes:

    * `render/1` — a list of lightweight rows for the index endpoint,
      each with the parent application's name inlined for grouping.
    * `render_one/1` — a single deployment for the show endpoint, with
      per-server `steps` attached.
    * `render_created/1` — the response body for `create` and `rollback`;
      the same basic shape as a row, no steps attached.

  Tested directly — no controller plumbing required.
  """

  alias Still.Deployments
  alias Still.Deployments.Deployment
  alias Still.Deployments.DeploymentStep

  @doc "Renders a list of deployments for the index endpoint."
  def render(deployments) when is_list(deployments) do
    %{data: Enum.map(deployments, &deployment_with_application/1)}
  end

  @doc "Renders a single deployment with steps for the show endpoint."
  def render_one(%Deployment{} = deployment) do
    %{data: deployment_with_steps(deployment)}
  end

  @doc "Renders a deployment after a create/rollback, no steps."
  def render_created(%Deployment{} = deployment) do
    %{data: deployment(deployment)}
  end

  @doc "Base shape — shared by every render path."
  def deployment(%Deployment{} = deployment) do
    %{
      id: deployment.id,
      application_id: deployment.application_id,
      version: deployment.version,
      artifact_url: deployment.artifact_url,
      status: deployment.status,
      initiated_by: deployment.initiated_by,
      source: deployment.source,
      error: deployment.error,
      started_at: deployment.started_at,
      completed_at: deployment.completed_at,
      duration_ms: Deployment.duration_ms(deployment),
      progress: maybe_progress(deployment),
      eta_at: Deployments.eta_at(deployment),
      inserted_at: deployment.inserted_at
    }
  end

  # Progress requires `:steps` preloaded. Base renders that skip a
  # preload (e.g. the create response) get `nil` for progress rather
  # than crashing — the client refetches when it wants step detail.
  defp maybe_progress(%Deployment{steps: %Ecto.Association.NotLoaded{}}), do: nil
  defp maybe_progress(%Deployment{} = deployment), do: Deployment.progress(deployment)

  @doc "Index-row shape: base + inline `application_name`."
  def deployment_with_application(%Deployment{application: %{name: name}} = deployment) do
    deployment |> deployment() |> Map.put(:application_name, name)
  end

  @doc "Show shape: base + `steps`."
  def deployment_with_steps(%Deployment{steps: steps} = deployment) when is_list(steps) do
    deployment |> deployment() |> Map.put(:steps, Enum.map(steps, &step/1))
  end

  @doc "Single step row."
  def step(%DeploymentStep{} = step) do
    %{
      id: step.id,
      server_id: step.server_id,
      status: step.status,
      error: step.error,
      started_at: step.started_at,
      completed_at: step.completed_at
    }
  end
end
