defmodule StillWeb.Schemas.Deployment do
  @moduledoc "A single deployment record. Index/show shapes layer on `application_name` and `steps`."

  require OpenApiSpex

  alias StillWeb.Schemas.{DeploymentProgress, DeploymentStep}

  OpenApiSpex.schema(%{
    title: "Deployment",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      application_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      version: %OpenApiSpex.Schema{type: :string},
      artifact_url: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{
        type: :string,
        enum: ["pending", "in_progress", "completed", "failed", "rolled_back"]
      },
      initiated_by: %OpenApiSpex.Schema{
        type: :string,
        description: "Actor identity — typically 'user:<email>' or 'api:<email>'."
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        maxLength: 255,
        description: ~S"""
        Optional provenance string describing what produced this deploy —
        e.g. `git:main@abc1234`, `ci:nightly-prod`, `rollback`.
        Complements `initiated_by` (who) with context (what).
        """
      },
      error: %OpenApiSpex.Schema{type: :string, nullable: true},
      started_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      completed_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      duration_ms: %OpenApiSpex.Schema{
        type: :integer,
        nullable: true,
        description: "Wall-clock ms between started_at and completed_at; null until terminal."
      },
      progress: %OpenApiSpex.Schema{
        nullable: true,
        allOf: [DeploymentProgress],
        description: "Null on responses that don't preload steps (e.g. POST /deployments)."
      },
      eta_at: %OpenApiSpex.Schema{
        type: :string,
        format: :"date-time",
        nullable: true,
        description: ~S"""
        Estimated completion timestamp for an in-flight deploy, based on
        the rolling average step duration of recent successful deploys
        for this application. Null for terminal deploys and when no
        history exists to estimate from.
        """
      },
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      application_name: %OpenApiSpex.Schema{
        type: :string,
        nullable: true,
        description: "Inlined on index responses; null elsewhere."
      },
      steps: %OpenApiSpex.Schema{
        type: :array,
        nullable: true,
        items: DeploymentStep,
        description: "Per-server step rows, included on the show response only."
      }
    },
    required: [:id, :application_id, :version, :artifact_url, :status, :initiated_by]
  })
end
