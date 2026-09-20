# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Type.RangeBound do
  @moduledoc """
  Encodes one value the way `AshSqlite.Type.Range` encodes a range's bounds.

  This exists so that a point compared against a range is encoded by the *same*
  function that encoded the bounds, rather than by the adapter's own datetime
  codec. The two do not agree, and the disagreement is silent:
  `DateTime.to_iso8601/1` preserves whatever precision the value carries, so
  `~U[2026-01-15 00:00:00Z]` encodes as `"2026-01-15T00:00:00Z"` while a bound
  normalised to microseconds encodes as `"2026-01-15T00:00:00.000000Z"`.
  Compared as text, `"Z"` (0x5A) sorts above `"."` (0x2E), so two spellings of
  one instant compare unequal, and in the wrong direction.

  Only the range functions route through this type; ordinary datetime columns are
  still encoded by the adapter.
  """

  use Ecto.ParameterizedType

  # The encoding is the same for every inner type `Ash.Type.Range` allows, so
  # there is nothing to parameterise. This is a parameterized type only because
  # that is the shape Ecto accepts when Ash passes an attribute's constraints
  # through as field options.
  @impl true
  def init(_opts), do: %{}

  @impl true
  def type(_params), do: :string

  @impl true
  def cast(value, _params), do: {:ok, value}

  @impl true
  def dump(value, _dumper, _params), do: {:ok, encode(value)}

  @impl true
  def load(value, _loader, _params), do: {:ok, value}

  @doc """
  Encodes a bound into the text form ranges compare on.

  Datetimes are forced to microsecond precision, because ISO8601 only orders
  lexicographically among strings of equal precision. `Ash.Type.Range` limits
  inner types to date, integer, naive_datetime and datetime, so there is no
  inner type here whose Elixir form needs anything cleverer than this.
  """
  def encode(nil), do: nil
  def encode(%DateTime{} = value), do: value |> force_usec() |> DateTime.to_iso8601()
  def encode(%NaiveDateTime{} = value), do: value |> force_usec() |> NaiveDateTime.to_iso8601()
  def encode(%Date{} = value), do: Date.to_iso8601(value)
  def encode(value), do: value

  defp force_usec(%{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}
end
