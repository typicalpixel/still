defmodule Still.DeploymentsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Still.Deployments` context.

  All fixtures accept an optional attrs map that will override the generated defaults.
  """

  alias Still.Audit.Actor

  @doc """
  Generate a deployment for the given application.

  The application must already have at least one server assigned, otherwise
  `Still.Deployments.create_deployment/2` returns `{:error, :no_servers_assigned}`.
  """
  def deployment_fixture(%Still.Applications.Application{} = application, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, deployment} =
      attrs
      |> Enum.into(%{
        version: "0.0.#{n}+abc#{n}",
        artifact_url: "https://example.com/app-#{n}.tar.gz",
        initiated_by: "test:fixture"
      })
      |> then(&Still.Deployments.create_deployment(Actor.system(), application, &1))

    deployment
  end
end
