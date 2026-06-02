defmodule StillWeb.Schemas.Envelope do
  @moduledoc """
  Helpers for the standard `{"data": ...}` response envelope. Use these
  inline in `operation/3` responses to avoid creating a one-off
  XxxResponse module for every shape.

      responses: [
        ok: {"Servers", "application/json", Envelope.list(Schemas.Server)},
        ok: {"Server", "application/json", Envelope.single(Schemas.Server)}
      ]
  """

  alias OpenApiSpex.Schema

  @doc "Builds a `{data: [item, ...]}` schema."
  def list(item) when is_atom(item) or is_struct(item, Schema) do
    %Schema{
      type: :object,
      properties: %{data: %Schema{type: :array, items: item}},
      required: [:data]
    }
  end

  @doc "Builds a `{data: item}` schema."
  def single(item) when is_atom(item) or is_struct(item, Schema) do
    %Schema{
      type: :object,
      properties: %{data: item},
      required: [:data]
    }
  end
end
