defmodule Still.ApplicationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Still.Applications` context.

  All fixtures accept an optional attrs map that will override the generated defaults.
  """

  alias Still.Audit.Actor

  @doc """
  Generate a valid health check map.
  """
  def valid_health_check_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      path: "/health",
      interval_ms: 5000,
      deadline_ms: 3000
    })
  end

  @doc """
  Generate a valid artifact source map.
  """
  def valid_artifact_source_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{type: :unauthenticated_url})
  end

  @doc """
  Generate an application. Defaults produce a valid `:elixir_release` app.
  """
  def application_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, application} =
      attrs
      |> Enum.into(%{
        name: "app-#{n}",
        type: :elixir_release,
        domain: "app-#{n}.example.com",
        exec_command: "bin/app start",
        env_vars: %{},
        min_healthy: 1,
        health_check: valid_health_check_attrs(),
        artifact_source: valid_artifact_source_attrs()
      })
      |> then(&Still.Applications.create_application(Actor.system(), &1))

    application
  end

  @doc """
  Assigns a server to an application using auto-assigned ports unless overridden.
  """
  def application_server_fixture(
        %Still.Applications.Application{} = application,
        %Still.Fleet.Server{} = server,
        attrs \\ %{}
      ) do
    {:ok, assignment} =
      Still.Applications.assign_server(Actor.system(), application, server, attrs)

    assignment
  end

  @doc """
  Generate a hook for the given application. Defaults to a `:pre_deploy` event
  with a trivial script.
  """
  def hook_fixture(%Still.Applications.Application{} = application, attrs \\ %{}) do
    {:ok, hook} =
      attrs
      |> Enum.into(%{
        event: :pre_deploy,
        script: "#!/bin/bash\necho hello",
        timeout_ms: 30_000
      })
      |> then(&Still.Applications.create_hook(Actor.system(), application, &1))

    hook
  end
end
