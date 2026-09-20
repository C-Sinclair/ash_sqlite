# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.RangeTest do
  @moduledoc """
  `Ash.Type.Range` on SQLite, checked against `Ash.Range` as the oracle.

  Every range predicate here is compiled to comparisons on `json_extract`, and
  the thing that can quietly go wrong is not whether the SQL runs but whether it
  answers the same question `Ash.Range` answers in Elixir. So each test asserts
  agreement with `Ash.Range.intersects?/2`, `contains?/2` or `adjacent?/2` over a
  set of pairs chosen to include the cases where inclusivity decides the answer:
  ranges that merely touch, and ranges that touch with every combination of
  bounds.
  """
  use AshSqlite.RepoCase, async: false

  import Ash.Expr, only: [expr: 1]

  require Ash.Query

  alias AshSqlite.TestRepo

  defmodule Reservation do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: AshSqlite.DataLayer

    sqlite do
      table("range_reservations")
      repo(AshSqlite.TestRepo)
    end

    actions do
      default_accept(:*)
      defaults([:create, :read, :update, :destroy])
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, public?: true)
      attribute(:window, Ash.Type.Range, constraints: [inner_type: :datetime], public?: true)
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false
    resources(do: resource(Reservation))
  end

  setup do
    TestRepo.query!("DROP TABLE IF EXISTS range_reservations")

    TestRepo.query!("""
    CREATE TABLE range_reservations (
      id TEXT PRIMARY KEY,
      label TEXT,
      window TEXT
    )
    """)

    :ok
  end

  defp day(n), do: DateTime.new!(Date.new!(2026, 1, n), ~T[00:00:00], "Etc/UTC")

  defp range(lower, upper, bounds \\ :"[)") do
    %Ash.Range{lower: lower, upper: upper, bounds: bounds}
  end

  # The cases where inclusivity is the whole answer: [1,2) vs [2,3) do not
  # overlap, but [1,2] vs [2,3) do, and the SQL has to distinguish them.
  defp cases do
    [
      {"jan1_jan2", range(day(1), day(2))},
      {"jan1_jan2_closed", range(day(1), day(2), :"[]")},
      {"jan2_jan3", range(day(2), day(3))},
      {"jan2_jan3_open_lower", range(day(2), day(3), :"(]")},
      {"jan1_jan5", range(day(1), day(5))},
      {"jan3_jan4", range(day(3), day(4))},
      {"unbounded_lower", range(nil, day(2))},
      {"unbounded_upper", range(day(4), nil)},
      {"unbounded_both", range(nil, nil)}
    ]
  end

  defp seed! do
    for {label, window} <- cases() do
      Reservation
      |> Ash.Changeset.for_create(:create, %{label: label, window: window}, domain: Domain)
      |> Ash.create!()
    end
  end

  defp labels_matching(filter) do
    Reservation
    |> Ash.Query.do_filter(filter)
    |> Ash.read!(domain: Domain)
    |> Enum.map(& &1.label)
    |> Enum.sort()
  end

  defp expected(oracle) do
    cases()
    |> Enum.filter(fn {_label, window} -> oracle.(window) end)
    |> Enum.map(fn {label, _window} -> label end)
    |> Enum.sort()
  end

  describe "round trip" do
    test "a range survives a write and a read" do
      window = range(day(1), day(2), :"[]")

      created =
        Reservation
        |> Ash.Changeset.for_create(:create, %{label: "a", window: window}, domain: Domain)
        |> Ash.create!()

      assert [read] = Ash.read!(Reservation, domain: Domain)
      assert read.id == created.id
      assert read.window == window
    end

    test "an unbounded side round trips as nil, not as a sentinel" do
      Reservation
      |> Ash.Changeset.for_create(:create, %{label: "a", window: range(nil, nil)}, domain: Domain)
      |> Ash.create!()

      assert [%{window: window}] = Ash.read!(Reservation, domain: Domain)
      assert window.lower == nil
      assert window.upper == nil
    end

    test "bounds are stored at a single precision" do
      # A range written at second precision and one written at microsecond
      # precision must be stored identically, or they compare wrongly as text.
      second = DateTime.new!(Date.new!(2026, 1, 1), ~T[00:00:00], "Etc/UTC")
      usec = %{second | microsecond: {0, 6}}

      for {label, lower} <- [{"second", second}, {"usec", usec}] do
        Reservation
        |> Ash.Changeset.for_create(:create, %{label: label, window: range(lower, day(2))},
          domain: Domain
        )
        |> Ash.create!()
      end

      stored =
        TestRepo.query!(
          "SELECT json_extract(window, '$.lower') FROM range_reservations ORDER BY label"
        ).rows
        |> List.flatten()
        |> Enum.uniq()

      assert stored == ["2026-01-01T00:00:00.000000Z"]
    end
  end

  describe "range_overlaps/2" do
    test "agrees with Ash.Range.intersects?/2" do
      seed!()

      for {label, probe} <- cases() do
        assert labels_matching(expr(range_overlaps(window, ^probe))) ==
                 expected(&Ash.Range.intersects?(&1, probe)),
               "range_overlaps disagreed with Ash.Range.intersects?/2 for #{label}"
      end
    end

    test "a null range matches nothing" do
      Reservation
      |> Ash.Changeset.for_create(:create, %{label: "no_window", window: nil}, domain: Domain)
      |> Ash.create!()

      assert labels_matching(expr(range_overlaps(window, ^range(day(1), day(9))))) == []
    end
  end

  describe "range_contains/2" do
    test "range in range agrees with Ash.Range.contains?/2" do
      seed!()

      for {label, probe} <- cases() do
        assert labels_matching(expr(range_contains(window, ^probe))) ==
                 expected(&Ash.Range.contains?(&1, probe)),
               "range_contains disagreed with Ash.Range.contains?/2 for #{label}"
      end
    end

    test "point in range agrees with Ash.Range.contains?/2" do
      seed!()

      for point <- [day(1), day(2), day(3), day(4), day(5)] do
        assert labels_matching(expr(range_contains(window, ^point))) ==
                 expected(&Ash.Range.contains?(&1, point)),
               "range_contains disagreed with Ash.Range.contains?/2 for point #{point}"
      end
    end

    test "a point at second precision is not treated as a different instant" do
      # The adapter would encode this as "...00:00:00Z" and the bound as
      # "...00:00:00.000000Z", which compare unequal as text.
      Reservation
      |> Ash.Changeset.for_create(
        :create,
        %{label: "a", window: range(%{day(1) | microsecond: {0, 6}}, day(5))},
        domain: Domain
      )
      |> Ash.create!()

      point = DateTime.new!(Date.new!(2026, 1, 1), ~T[00:00:00], "Etc/UTC")

      assert labels_matching(expr(range_contains(window, ^point))) == ["a"]
    end
  end

  describe "range_adjacent/2" do
    test "agrees with Ash.Range.adjacent?/2" do
      seed!()

      for {label, probe} <- cases() do
        assert labels_matching(expr(range_adjacent(window, ^probe))) ==
                 expected(&Ash.Range.adjacent?(&1, probe)),
               "range_adjacent disagreed with Ash.Range.adjacent?/2 for #{label}"
      end
    end
  end

  describe "range_lower/1 and range_upper/1" do
    test "select a range's bounds" do
      Reservation
      |> Ash.Changeset.for_create(:create, %{label: "a", window: range(day(1), day(2))},
        domain: Domain
      )
      |> Ash.create!()

      assert [%{lower: lower, upper: upper}] =
               Reservation
               |> Ash.Query.select([:id])
               |> Ash.Query.calculate(:lower, :datetime, expr(range_lower(window)))
               |> Ash.Query.calculate(:upper, :datetime, expr(range_upper(window)))
               |> Ash.read!(domain: Domain)
               |> Enum.map(&%{lower: &1.calculations.lower, upper: &1.calculations.upper})

      assert DateTime.compare(lower, day(1)) == :eq
      assert DateTime.compare(upper, day(2)) == :eq
    end
  end
end
