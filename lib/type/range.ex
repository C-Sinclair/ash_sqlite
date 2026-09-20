# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Type.Range do
  @moduledoc """
  Stores an `Ash.Type.Range` as a single JSON text column.

  SQLite has no range type and no GiST, so the two things Postgres gets from
  `tstzrange` -- a native column and an exclusion constraint -- have to be built
  from what SQLite does have. The column half is this type. The constraint half
  is the caller's: SQLite cannot express non-overlap declaratively, so a
  no-overlap guarantee has to come from a trigger or from a single writer.

  The stored shape is a JSON object whose keys are the ones `Ash.Type.Range`
  already destructures on the way back in, so `load/1` hands Ash a plain map and
  Ash casts each bound with the inner type's `cast_stored/2`:

      {"lower": "2026-01-01T00:00:00.000000Z", "upper": null, "bounds": "[)", "empty": false}

  Two properties are load-bearing, and both are about comparison rather than
  storage, because every range predicate compiles to comparisons on
  `json_extract` of these keys:

  * **Bounds are encoded by `AshSqlite.Type.RangeBound`**, so datetimes compare
    lexicographically as ISO8601 at a single fixed precision. See that module
    for what goes silently wrong when the two sides of a comparison are encoded
    by different code.
  * **An absent bound is JSON `null`**, which `json_extract` returns as SQL
    NULL, so "unbounded" is tested with `IS NULL` rather than against a
    sentinel. A sentinel would have to be a value of the inner type, and there
    is no one value that works for every inner type.
  """

  use Ecto.ParameterizedType

  alias AshSqlite.Type.RangeBound

  # Ash passes an attribute's constraints through as field options, so this is
  # where the inner type arrives. It is needed on the way *out* only: encoding a
  # bound is the same for every inner type the range allows, but decoding one
  # has to go through that type's `cast_stored/2`. The query path initialises
  # this type with no options, because it only ever dumps.
  @impl true
  def init(opts) do
    %{
      inner_type: opts[:inner_type],
      inner_constraints: opts[:inner_constraints] || []
    }
  end

  @impl true
  def type(_params), do: :string

  @impl true
  def cast(nil, _params), do: {:ok, nil}
  def cast(%Ash.Range{} = range, _params), do: {:ok, range}
  def cast(value, params) when is_binary(value), do: load(value, nil, params)
  def cast(_value, _params), do: :error

  @impl true
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(%Ash.Range{empty?: true}, _dumper, _params) do
    {:ok, Jason.encode!(%{"lower" => nil, "upper" => nil, "bounds" => "[)", "empty" => true})}
  end

  def dump(%Ash.Range{} = range, _dumper, _params) do
    {:ok,
     Jason.encode!(%{
       "lower" => RangeBound.encode(range.lower),
       "upper" => RangeBound.encode(range.upper),
       "bounds" => to_string(range.bounds),
       "empty" => false
     })}
  end

  def dump(_value, _dumper, _params), do: :error

  @impl true
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(value, _loader, params) when is_binary(value) do
    with {:ok, %{"bounds" => bounds} = decoded} <- Jason.decode(value),
         {:ok, bounds} <- decode_bounds(bounds),
         {:ok, lower} <- decode_bound(decoded["lower"], params),
         {:ok, upper} <- decode_bound(decoded["upper"], params) do
      {:ok,
       %Ash.Range{
         lower: lower,
         upper: upper,
         bounds: bounds,
         empty?: decoded["empty"] || false
       }}
    else
      _other -> :error
    end
  end

  def load(_value, _loader, _params), do: :error

  # Ash does not cast an attribute Ecto has already loaded, so the value handed
  # back here has to be the finished `Ash.Range`, bounds included.
  defp decode_bound(nil, _params), do: {:ok, nil}

  defp decode_bound(value, %{inner_type: nil}), do: {:ok, value}

  defp decode_bound(value, %{inner_type: inner_type, inner_constraints: inner_constraints}) do
    Ash.Type.cast_stored(inner_type, value, inner_constraints)
  end

  @bounds ["[)", "[]", "(]", "()"]
  defp decode_bounds(bounds) when bounds in @bounds, do: {:ok, String.to_atom(bounds)}
  defp decode_bounds(_bounds), do: :error
end
