defmodule Still.Audit.Actor do
  @moduledoc """
  Identifies who or what initiated an audited action.

  Built once at the controller boundary from `conn` (`from_conn/1`) and
  threaded through context functions as the first argument. System paths
  that have no human at the wheel — the orchestrator, the reconciliation
  loop, agent message handlers — use `system/0` or `agent/2`.

  The `label` field is captured at write time and persisted onto every
  audit row so the row stays readable after the underlying user, API
  key, or server is deleted.
  """

  alias Still.Accounts.{ApiKey, Scope, User}
  alias Still.Fleet.Server

  @kinds [:user, :api_key, :agent, :anonymous, :system]

  @enforce_keys [:kind, :label]
  defstruct [:kind, :label, :user_id, :api_key_id, :server_id, :ip, :user_agent]

  @doc "Returns the list of valid actor kinds."
  def kinds, do: @kinds

  @doc """
  System actor for backend-initiated actions (orchestrator, reconciler,
  background jobs).
  """
  def system, do: %__MODULE__{kind: :system, label: "system"}

  @doc """
  Anonymous actor for unauthenticated request paths — bootstrap, login
  attempts (succeeded or failed), and Auth-plug rejections. IP and
  User-Agent are captured separately via `with_conn/2` so the audit row
  still answers "where did the attempt come from".
  """
  def anonymous, do: %__MODULE__{kind: :anonymous, label: "anonymous"}

  @doc """
  Agent actor for agent-initiated actions (announcements, health
  transitions reported by an agent). The label includes the server's
  display name so the audit row stays meaningful after the server is
  removed from the fleet.
  """
  def agent(%Server{} = server) do
    %__MODULE__{
      kind: :agent,
      label: "agent:#{server.name}",
      server_id: server.id
    }
  end

  @doc "Agent actor built from a server id and display name."
  def agent(server_id, server_name) when is_binary(server_id) and is_binary(server_name) do
    %__MODULE__{
      kind: :agent,
      label: "agent:#{server_name}",
      server_id: server_id
    }
  end

  @doc """
  Builds an actor from a Plug conn. Pulls user / api_key from
  `conn.assigns.current_scope`, captures remote IP and User-Agent for
  SOC 2 access logs. Falls back to `system/0` (with conn metadata) when
  the conn has no scope — e.g. unauthenticated routes that still want
  to record an attempt.
  """
  def from_conn(%Plug.Conn{} = conn) do
    case conn.assigns[:current_scope] do
      %Scope{} = scope -> scope |> from_scope() |> with_conn(conn)
      _ -> with_conn(anonymous(), conn)
    end
  end

  @doc """
  Builds an actor from a scope alone — no IP / User-Agent, since there
  is no live request. Used by tests and any path that has a scope
  without a conn.
  """
  def from_scope(%Scope{api_key: %ApiKey{} = api_key, user: %User{} = user}) do
    %__MODULE__{
      kind: :api_key,
      label: "key:#{api_key.name || "?"} (#{user.email || user_fallback(user)})",
      user_id: user.id,
      api_key_id: api_key.id
    }
  end

  def from_scope(%Scope{api_key: nil, user: %User{} = user}) do
    %__MODULE__{kind: :user, label: user.email || user_fallback(user), user_id: user.id}
  end

  def from_scope(%Scope{user: nil, api_key: nil}), do: anonymous()

  # Fallback label for the rare case a user struct has no email — synthetic
  # test fixtures, mostly. Production users always have emails (NOT NULL
  # constraint), but the audit insert must not crash if one slips through.
  defp user_fallback(%User{id: nil}), do: "user:unknown"
  defp user_fallback(%User{id: id}), do: "user:#{id}"

  @doc """
  Stamps an actor with the conn's remote IP and User-Agent. Useful when
  a non-conn caller (e.g. an auth plug that has the user but not yet a
  scope) needs to enrich a system/from_scope-built actor.
  """
  def with_conn(%__MODULE__{} = actor, %Plug.Conn{} = conn) do
    %{actor | ip: format_ip(conn.remote_ip), user_agent: user_agent(conn)}
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  defp user_agent(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> nil
    end
  end
end
