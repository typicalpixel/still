defmodule StillWeb.APIVersion do
  @moduledoc """
  Tracks the Still API version, Stripe-style date-based.

  The version is the ISO-8601 date of the most recent breaking change to the
  API. New endpoints, new fields, and new query params are additive and do
  not move the version. Clients pin a version via the `Still-API-Version`
  request header; the same header is echoed on every response.

  ## Current status

  The plumbing is in place: `current/0` is returned in `GET /api/status`
  and the module is ready for a Plug that emits the response header and
  reads the request header for version pinning. That Plug is deferred
  until the API stabilizes — while Still has a single user the version
  is informational only and the header machinery adds no value.
  """

  @current "2026-04-09"

  @doc """
  Returns the current Still API version as an ISO-8601 date string.
  """
  def current, do: @current
end
