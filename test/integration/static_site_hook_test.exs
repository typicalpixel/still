defmodule Still.Integration.StaticSiteHookTest do
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  @application "integration-static-hooks"

  describe "hook execution during deploy" do
    test "runs pre_deploy and post_deploy hooks with Still env vars", %{
      caddy: caddy,
      applications_dir: apps_dir
    } do
      pre_marker = Path.join(apps_dir, "pre-deploy-marker")
      post_marker = Path.join(apps_dir, "post-deploy-marker")

      spec = %{
        application: @application,
        type: :static_site,
        version: "0.0.1-hooks",
        artifact_url: IntegrationFixtures.file_url(:static_a),
        artifact_provider: Still.Artifact.Provider.LocalFile,
        domain: "localhost",
        env_vars: %{"APP_KEY" => "forty-two"},
        exec_command: nil,
        health_check: nil,
        hooks: %{
          pre_deploy: %{
            script: """
            set -eu
            echo "app=$STILL_APPLICATION version=$STILL_RELEASE_VERSION type=$STILL_TYPE slot=$STILL_TARGET_SLOT app_key=$APP_KEY" > #{pre_marker}
            """,
            timeout_ms: 5_000
          },
          post_deploy: %{
            script: """
            set -eu
            echo "app=$STILL_APPLICATION version=$STILL_RELEASE_VERSION type=$STILL_TYPE" > #{post_marker}
            """,
            timeout_ms: 5_000
          }
        },
        port_blue: nil,
        port_green: nil
      }

      start_supervised!(DeploymentManager)

      assert {:ok, "0.0.1-hooks"} = DeploymentManager.deploy(spec)

      # The Caddy flip happened normally — the deploy didn't just
      # silently skip everything because of a hook error.
      assert fetch_home(caddy.http_port) =~ "still-fixture-static vA"

      assert File.exists?(pre_marker), "pre_deploy hook did not run"
      assert File.exists?(post_marker), "post_deploy hook did not run"

      # Env vars were plumbed through: Still-prefixed + app env_vars merged.
      pre_contents = File.read!(pre_marker)
      assert pre_contents =~ "app=#{@application}"
      assert pre_contents =~ "version=0.0.1-hooks"
      assert pre_contents =~ "type=static_site"
      assert pre_contents =~ ~r/slot=(blue|green)/
      assert pre_contents =~ "app_key=forty-two"

      post_contents = File.read!(post_marker)
      assert post_contents =~ "app=#{@application}"
      assert post_contents =~ "version=0.0.1-hooks"
    end

    test "fails the deploy when a pre_deploy hook exits non-zero", %{
      applications_dir: _apps_dir
    } do
      spec = %{
        application: "#{@application}-fail-pre",
        type: :static_site,
        version: "0.0.1",
        artifact_url: IntegrationFixtures.file_url(:static_a),
        artifact_provider: Still.Artifact.Provider.LocalFile,
        domain: "localhost",
        env_vars: %{},
        exec_command: nil,
        health_check: nil,
        hooks: %{
          pre_deploy: %{
            script: """
            echo "deliberate failure" >&2
            exit 7
            """,
            timeout_ms: 5_000
          }
        },
        port_blue: nil,
        port_green: nil
      }

      start_supervised!(DeploymentManager)

      assert {:error, %{step: :pre_deploy, reason: reason}} = DeploymentManager.deploy(spec)
      assert reason =~ "pre_deploy hook exit 7"
      assert reason =~ "deliberate failure"
    end

    test "fails the deploy when a hook exceeds its timeout_ms" do
      spec = %{
        application: "#{@application}-timeout",
        type: :static_site,
        version: "0.0.1",
        artifact_url: IntegrationFixtures.file_url(:static_a),
        artifact_provider: Still.Artifact.Provider.LocalFile,
        domain: "localhost",
        env_vars: %{},
        exec_command: nil,
        health_check: nil,
        hooks: %{
          pre_deploy: %{
            script: "sleep 30",
            timeout_ms: 1_000
          }
        },
        port_blue: nil,
        port_green: nil
      }

      start_supervised!(DeploymentManager)

      assert {:error, %{step: :pre_deploy, reason: reason}} = DeploymentManager.deploy(spec)
      assert reason =~ "pre_deploy hook timed out after 1000ms"
    end
  end

  defp fetch_home(http_port) do
    %{status: 200, body: body} = Req.get!("http://localhost:#{http_port}/", retry: false)
    body
  end
end
