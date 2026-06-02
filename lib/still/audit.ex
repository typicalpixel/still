defmodule Still.Audit do
  @moduledoc """
  The Audit context — durable record of who did what when.

  Every operational mutation (config changes, auth events, deploy
  lifecycle, agent-driven state changes) is captured here as an
  append-only `audit_events` row. The same call also emits the event
  onto the unified live stream (`events:lobby` via `Still.EventLog`)
  so the dashboard's activity feed updates in real time.

  Callers always provide an `%Actor{}` so every row records the
  initiator. Controllers build the actor with `Actor.from_conn/1`;
  background callers use `Actor.system/0` or `Actor.agent/1`.

  Reads go through `list/1` with filters (`:type`, `:actor_user_id`,
  `:subject_type`, `:subject_id`, `:since`, `:until`, `:limit`).
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Still.Audit.{Actor, AuditEvent}
  alias Still.{EventLog, Repo}

  @default_limit 50
  @max_limit 500

  @doc """
  Records an audit event and emits it onto the live event stream.
  Convenience wrapper for callers that don't need to bundle the audit
  with another mutation — runs its own single-step transaction and
  emits live only after the commit succeeds.

  For mutations that need to be atomic with the audit, build an
  `Ecto.Multi` with `multi/3`, run `Repo.transaction/1`, then call
  `emit_live/1` on the returned row.

  Required:

    * `:actor` — `%Actor{}` identifying who initiated the action.
    * `:type` — atom event type (e.g. `:application_server_unassigned`).

  Optional:

    * `:subject_type` / `:subject_id` — what was acted on. Strings or
      atoms; atoms are normalized to strings.
    * `:payload` — type-specific data the dashboard renders. Actor
      kind/label are merged in automatically before the live emit.
    * `:before` / `:after` — pre/post-state snapshots. Stored on the
      row but not included in the live emit.

  Returns `{:ok, %AuditEvent{}}` on success or `{:error, changeset}`
  if the row failed validation.
  """
  def record(%Actor{} = actor, opts) when is_list(opts) do
    Multi.new()
    |> multi(actor, fn _ -> opts end)
    |> Repo.transaction()
    |> case do
      {:ok, %{audit: event}} ->
        emit_live(event)
        {:ok, event}

      {:error, :audit, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Appends an audit step to an `Ecto.Multi`. The `build_opts` function
  receives the changes accumulated so far and returns the keyword list
  of options that `record/2` accepts. Use this from context functions
  to bundle an operational mutation and the audit insert into a single
  atomic transaction.

      Multi.new()
      |> Multi.delete(:assignment, assignment)
      |> Audit.multi(actor, fn %{assignment: deleted} ->
        [type: :application_server_unassigned, subject_id: deleted.id, ...]
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{assignment: deleted, audit: event}} ->
          Audit.emit_live(event)
          {:ok, deleted}

        {:error, :assignment, changeset, _} ->
          {:error, changeset}
      end

  The audit insert itself participates in rollback if any later step
  fails. The live PubSub emit is **not** part of the multi — call
  `emit_live/1` only after `Repo.transaction/1` returns `{:ok, _}`,
  so a rolled-back transaction never produces a phantom event.
  """
  def multi(%Multi{} = multi, %Actor{} = actor, build_opts) when is_function(build_opts, 1) do
    Multi.run(multi, :audit, fn _repo, changes ->
      attrs = build_attrs(actor, build_opts.(changes))

      %AuditEvent{}
      |> AuditEvent.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc """
  Broadcasts an already-persisted audit event onto the live event
  stream. Called by `record/2` automatically; multi-based callers
  invoke this themselves after a successful `Repo.transaction/1`.
  """
  def emit_live(%AuditEvent{} = event) do
    EventLog.record(%{
      id: event.id,
      type: String.to_atom(event.type),
      payload:
        Map.merge(event.payload || %{}, %{
          actor_kind: event.actor_kind,
          actor_label: event.actor_label
        }),
      at: event.inserted_at
    })
  end

  defp build_attrs(%Actor{} = actor, opts) when is_list(opts) do
    type = Keyword.fetch!(opts, :type)

    %{
      type: to_string(type),
      subject_type: maybe_to_string(opts[:subject_type]),
      subject_id: opts[:subject_id],
      payload: Keyword.get(opts, :payload, %{}),
      before: opts[:before],
      after: opts[:after],
      actor_kind: actor.kind,
      actor_label: actor.label,
      actor_user_id: actor.user_id,
      actor_api_key_id: actor.api_key_id,
      actor_server_id: actor.server_id,
      ip: actor.ip,
      user_agent: actor.user_agent
    }
  end

  @doc """
  Renders an Ecto schema struct as a plain map suitable for the
  `before` / `after` columns. Recurses into embedded schemas, plain
  maps, and lists; passes through `DateTime`/`Date`/`Time`/`NaiveDateTime`
  unchanged so Jason can encode them. Drops `__meta__` and association
  fields by relying on `__schema__(:fields)`. Returns `nil` for `nil`.
  """
  def snapshot(nil), do: nil

  def snapshot(value) when is_struct(value) or is_map(value) or is_list(value) do
    do_snapshot(value)
  end

  defp do_snapshot(%DateTime{} = dt), do: dt
  defp do_snapshot(%Date{} = d), do: d
  defp do_snapshot(%Time{} = t), do: t
  defp do_snapshot(%NaiveDateTime{} = dt), do: dt

  # Drops `__meta__`, association fields, and any field marked
  # `redact: true` on the schema (hashed_password, hashed_key,
  # virtual `:raw_key`, etc.) so secrets never make it into the
  # audit log.
  defp do_snapshot(%schema{} = struct) when is_atom(schema) do
    if function_exported?(schema, :__schema__, 1) do
      redacted = schema.__schema__(:redact_fields)
      fields = schema.__schema__(:fields) -- redacted
      Map.new(fields, fn field -> {field, do_snapshot(Map.get(struct, field))} end)
    else
      struct
    end
  end

  defp do_snapshot(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, do_snapshot(v)} end)
  end

  defp do_snapshot(value) when is_list(value), do: Enum.map(value, &do_snapshot/1)

  # A non-redacted `:binary` field can hold non-UTF8 bytes that crash
  # JSON encoding. Base64 it instead so the snapshot stays writable.
  defp do_snapshot(value) when is_binary(value) do
    if String.valid?(value), do: value, else: Base.encode64(value)
  end

  defp do_snapshot(value), do: value

  @doc """
  Lists audit events, newest first. Supports filters:

    * `:type` — string or atom; matches `events.type` exactly.
    * `:actor_user_id` / `:actor_api_key_id` / `:actor_server_id` — UUIDs.
    * `:subject_type` / `:subject_id` — pair them to scope to a single subject.
    * `:since` / `:until` — ISO-8601 strings or `%DateTime{}`.
    * `:limit` — 1..500, default 50.
  """
  def list(filters \\ %{})

  def list(filters) when is_map(filters) do
    AuditEvent
    |> apply_filter(:type, fetch(filters, :type))
    |> apply_filter(:actor_user_id, fetch(filters, :actor_user_id))
    |> apply_filter(:actor_api_key_id, fetch(filters, :actor_api_key_id))
    |> apply_filter(:actor_server_id, fetch(filters, :actor_server_id))
    |> apply_filter(:subject_type, fetch(filters, :subject_type))
    |> apply_filter(:subject_id, fetch(filters, :subject_id))
    |> apply_since(fetch(filters, :since))
    |> apply_until(fetch(filters, :until))
    |> order_by_recent()
    |> limit_query(fetch(filters, :limit, @default_limit))
    |> Repo.all()
  end

  def list(filters) when is_list(filters), do: list(Map.new(filters))

  defp apply_filter(query, _field, nil), do: query

  defp apply_filter(query, field, value) when is_atom(field) do
    value = to_string(value)
    from a in query, where: field(a, ^field) == ^value
  end

  defp apply_since(query, nil), do: query

  defp apply_since(query, %DateTime{} = dt) do
    from a in query, where: a.inserted_at >= ^dt
  end

  defp apply_since(query, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> apply_since(query, dt)
      _ -> query
    end
  end

  defp apply_until(query, nil), do: query

  defp apply_until(query, %DateTime{} = dt) do
    from a in query, where: a.inserted_at < ^dt
  end

  defp apply_until(query, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> apply_until(query, dt)
      _ -> query
    end
  end

  defp order_by_recent(query), do: from(a in query, order_by: [desc: a.inserted_at])

  defp limit_query(query, value), do: from(a in query, limit: ^clamp_limit(value))

  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> clamp_limit(int)
      _ -> @default_limit
    end
  end

  defp clamp_limit(_), do: @default_limit

  defp fetch(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_to_string(value) when is_binary(value), do: value
end
