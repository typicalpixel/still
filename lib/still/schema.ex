defmodule Still.Schema do
  @moduledoc """
  Base schema module for Still.

  All schemas should `use Still.Schema` instead of `use Ecto.Schema` so that
  they pick up project-wide defaults:

    * `binary_id` primary keys (UUIDs)
    * `binary_id` foreign keys
    * `:utc_datetime_usec` timestamps

  This is the single source of truth for those defaults — changing them here
  changes them everywhere.
  """

  @doc """
  Injects `Ecto.Schema` along with Still's project-wide schema defaults.
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
