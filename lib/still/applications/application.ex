defmodule Still.Applications.Application do
  @moduledoc """
  Application schema, with creation and update changesets.

  An application is the user-facing unit of deployment: a single named
  service with one type, one domain, one set of env vars, and one
  artifact source. The `name` and `type` are immutable after creation.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Applications.ArtifactSource
  alias Still.Applications.EnvVars
  alias Still.Applications.HealthCheck
  alias Still.Hostname

  @types [:elixir_release, :static_site, :process]

  schema "applications" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :domain, :string
    field :path_prefix, :string
    field :exec_command, :string
    field :exec_start_pre, :string
    field :exec_stop, :string
    field :exec_console, :string
    field :env_vars, :map, default: %{}
    field :min_healthy, :integer, default: 1
    field :maintenance, :boolean, default: false
    field :maintenance_message, :string

    embeds_one :health_check, HealthCheck, on_replace: :update
    embeds_one :artifact_source, ArtifactSource, on_replace: :update

    timestamps()
  end

  @doc """
  Returns the list of valid application types.
  """
  def types, do: @types

  @doc """
  Builds a changeset for creating a new application. `name` and `type` may
  only be set here.
  """
  def creation_changeset(%__MODULE__{} = application, attrs) when is_map(attrs) do
    application
    |> cast(attrs, [
      :name,
      :type,
      :domain,
      :path_prefix,
      :exec_command,
      :exec_start_pre,
      :exec_stop,
      :exec_console,
      :env_vars,
      :min_healthy
    ])
    |> cast_embed(:health_check)
    |> cast_embed(:artifact_source, required: true)
    |> validate_required([:name, :type, :domain, :min_healthy])
    |> common_validations()
    |> unique_constraint(:name)
  end

  @doc """
  Builds a changeset for updating an application. `name` and `type` are not
  cast — they cannot be changed after creation.
  """
  def update_changeset(%__MODULE__{} = application, attrs) when is_map(attrs) do
    application
    |> cast(attrs, [
      :domain,
      :path_prefix,
      :exec_command,
      :exec_start_pre,
      :exec_stop,
      :exec_console,
      :env_vars,
      :min_healthy,
      :maintenance,
      :maintenance_message
    ])
    |> cast_embed(:health_check)
    |> cast_embed(:artifact_source, required: true)
    |> validate_required([:domain, :min_healthy])
    |> common_validations()
  end

  defp common_validations(changeset) do
    changeset
    |> validate_format(:name, ~r/^[a-z][a-z0-9_-]*$/,
      message:
        "must start with a lowercase letter and contain only lowercase letters, digits, hyphens, and underscores"
    )
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:domain, min: 1, max: 255)
    |> validate_domain_format()
    |> validate_path_prefix()
    |> normalize_env_vars()
    |> validate_env_vars()
    |> validate_length(:maintenance_message, max: 500)
    |> validate_length(:exec_command, max: 1000)
    |> validate_length(:exec_start_pre, max: 1000)
    |> validate_length(:exec_stop, max: 1000)
    |> validate_length(:exec_console, max: 1000)
    |> validate_number(:min_healthy, greater_than_or_equal_to: 1)
    |> validate_type_specific_fields()
  end

  defp validate_domain_format(changeset) do
    validate_change(changeset, :domain, fn :domain, domain ->
      if Hostname.valid?(domain), do: [], else: [domain: "must be a valid IP address or hostname"]
    end)
  end

  defp validate_path_prefix(changeset) do
    case get_field(changeset, :path_prefix) do
      nil ->
        changeset

      prefix when is_binary(prefix) ->
        changeset
        |> validate_format(:path_prefix, ~r{^/}, message: "must start with /")
        |> validate_length(:path_prefix, max: 255)
    end
  end

  # Names are forced to uppercase-with-underscores (Doppler-style) so every
  # entry point — UI, API, fixtures — stores keys the same way.
  defp normalize_env_vars(changeset) do
    update_change(changeset, :env_vars, &EnvVars.normalize_map/1)
  end

  # Env vars become lines in a systemd EnvironmentFile (KEY=value), so a
  # non-string value would crash the deploy that writes the file and a newline
  # in a value would inject extra environment entries. Validate at the edge.
  defp validate_env_vars(changeset) do
    validate_change(changeset, :env_vars, fn :env_vars, vars ->
      Enum.find_value(vars, [], &env_var_error/1)
    end)
  end

  defp env_var_error({key, value}) do
    cond do
      not is_binary(key) ->
        [env_vars: "keys must be strings"]

      not Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) ->
        [env_vars: "key #{inspect(key)} must match ^[A-Za-z_][A-Za-z0-9_]*$"]

      not is_binary(value) ->
        [env_vars: "value for #{key} must be a string"]

      String.contains?(value, ["\n", "\0"]) ->
        [env_vars: "value for #{key} must not contain newlines or null bytes"]

      true ->
        nil
    end
  end

  defp validate_type_specific_fields(changeset) do
    case get_field(changeset, :type) do
      :static_site ->
        changeset
        |> require_nil(:exec_command, "must be blank for static_site applications")
        |> require_nil(:exec_start_pre, "must be blank for static_site applications")
        |> require_nil(:exec_stop, "must be blank for static_site applications")
        |> require_nil(:exec_console, "must be blank for static_site applications")
        |> require_nil_health_check()

      type when type in [:elixir_release, :process] ->
        changeset
        |> validate_required([:exec_command])
        |> require_present_health_check()

      _ ->
        changeset
    end
  end

  defp require_nil(changeset, field, message) do
    case get_field(changeset, field) do
      nil -> changeset
      _ -> add_error(changeset, field, message)
    end
  end

  defp require_nil_health_check(changeset) do
    case get_field(changeset, :health_check) do
      nil -> changeset
      _ -> add_error(changeset, :health_check, "must be blank for static_site applications")
    end
  end

  defp require_present_health_check(changeset) do
    case get_field(changeset, :health_check) do
      nil -> add_error(changeset, :health_check, "is required")
      _ -> changeset
    end
  end
end
