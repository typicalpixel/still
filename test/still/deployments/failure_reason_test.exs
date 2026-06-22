defmodule Still.Deployments.FailureReasonTest do
  use ExUnit.Case, async: true

  alias Still.Deployments.FailureReason

  describe "headline/1" do
    test "passes already-human strings through unchanged" do
      assert FailureReason.headline("tar exit 2: file not found") == "tar exit 2: file not found"
    end

    test "maps known atoms to plain English" do
      assert FailureReason.headline(:health_check_timeout) =~ "Health check timed out"
      assert FailureReason.headline(:app_crash_looped) =~ "crash-looped on boot"
      assert FailureReason.headline(:agent_disconnected) =~ "disconnected mid-deploy"
      assert FailureReason.headline(:no_previous_version) =~ "no previous version"
      assert FailureReason.headline(:no_rollback_target) =~ "no previous successful version"
      assert FailureReason.headline(:caddy_server_not_provisioned) =~ "Ingress (Caddy)"
    end

    test "maps a tuple reason" do
      assert FailureReason.headline({:state_unreadable, "api"}) =~
               "deploy state for api is unreadable"
    end

    test "reduces a step/reason map to its reason headline" do
      reason = %{step: :health_checking, reason: :app_crash_looped}
      assert FailureReason.headline(reason) =~ "crash-looped on boot"
    end

    test "falls back to the step name for an unknown reason in a map" do
      reason = %{step: :stopping_old, reason: :weird}
      assert FailureReason.headline(reason) == "stopping old failed: :weird"
    end

    test "keeps a human string carried inside a step/reason map" do
      reason = %{step: :unpacking, reason: "tar exit 2"}
      assert FailureReason.headline(reason) == "tar exit 2"
    end

    test "inspects an otherwise-unknown reason" do
      assert FailureReason.headline(:totally_unknown) == ":totally_unknown"
    end
  end
end
