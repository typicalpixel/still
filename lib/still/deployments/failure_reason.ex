defmodule Still.Deployments.FailureReason do
  @moduledoc """
  Turns a deploy failure into a short, human headline.

  The agent returns terse reasons — bare atoms (`:health_check_timeout`),
  `%{step:, reason:}` maps, or already-human strings from shellouts (a `tar`
  or hook error). This is the "what failed" line shown on the deployment and
  its step; the gory "why" lives in the captured deploy log.
  """

  @doc """
  A one-line headline for a failure reason. Already-human strings pass through
  unchanged; known atoms map to plain English; a `%{step:, reason:}` map is
  reduced to its reason (falling back to the step name for unknown reasons).
  """
  def headline(%{step: step, reason: reason}) do
    known(reason) || step_fallback(step, reason)
  end

  def headline(reason) when is_binary(reason), do: reason

  def headline(reason) when is_atom(reason) or is_tuple(reason),
    do: known(reason) || inspect(reason)

  defp known(:health_check_timeout),
    do:
      "Health check timed out — the application never returned a 2xx response on its health path."

  defp known(:app_crash_looped),
    do:
      "The application crash-looped on boot and systemd gave up — the cause is in the deploy log."

  defp known(:agent_disconnected),
    do: "The agent for this server disconnected mid-deploy."

  defp known(:no_previous_version),
    do: "There is no previous version to roll back to."

  defp known(:no_rollback_target),
    do: "There is no previous successful version to roll back to."

  defp known(:caddy_server_not_provisioned),
    do: "Ingress (Caddy) isn't provisioned on this server yet."

  defp known({:state_unreadable, application}),
    do:
      "The deploy state for #{application} is unreadable — refusing to overwrite a running slot."

  defp known(_reason), do: nil

  defp step_fallback(_step, reason) when is_binary(reason), do: reason

  defp step_fallback(step, reason),
    do: "#{humanize_step(step)} failed: #{inspect(reason)}"

  defp humanize_step(step), do: step |> to_string() |> String.replace("_", " ")
end
