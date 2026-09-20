# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Temporal.Migration do
  @moduledoc """
  The indexes and triggers a temporal table needs, as custom statements.

  Postgres gets all of this from one declaration: `PRIMARY KEY (id, valid_at WITHOUT
  OVERLAPS)` is both the uniqueness rule and, through its GiST index, the access path.
  SQLite has neither an exclusion constraint nor GiST, so the same guarantees are
  assembled from three pieces it does have.

  * **An index on `(key..., json_extract(period, '$.lower'))`.** The planner matches an
    index built on an expression to the same expression in a query, alias and quoting
    included, so a point-in-time read of one record is an index seek rather than a scan.
  * **A partial unique index over the open-ended period.** `UNIQUE (key...) WHERE
    json_extract(period, '$.upper') IS NULL` refuses a second current version for a key.
    This is a real constraint rather than a trigger, and it is the one that matters: a
    split that fails to close the prior version is exactly what it rejects.
  * **A pair of non-overlap triggers.** The partial index says nothing about two
    overlapping *closed* periods, which is the rest of `WITHOUT OVERLAPS`. A
    `BEFORE INSERT`/`BEFORE UPDATE` trigger rejects those with `RAISE(ABORT)`.

  These are emitted as custom statements so they reuse the generator's own diffing and
  its ordering guarantee: `down` statements run first and `up` statements last, which is
  what a trigger needs, since it cannot be created before its table.
  """

  # Against a released ash there is no temporal section, so `statements/1` is `[]` and
  # everything it would have called is dead code the compiler need not carry.
  if AshSqlite.Temporal.supported?() do
    @doc "The statements for `resource`, or `[]` when it is not temporal."
    def statements(resource) do
      case AshSqlite.Temporal.attribute(resource) do
        nil -> []
        attribute -> build(resource, attribute)
      end
    end

    defp build(resource, attribute) do
      table = AshSqlite.DataLayer.Info.table(resource)
      primary_key = Ash.Resource.Info.primary_key(resource)

      # Every identity gets the same treatment as the primary key. An identity on a
      # temporal resource is unique per period rather than per table, so the generator
      # drops it from the snapshot and it reappears here as a partial unique index plus a
      # trigger pair over its own keys.
      identities =
        resource
        |> Ash.Resource.Info.identities()
        |> Enum.map(& &1.keys)
        |> Enum.reject(&(Enum.sort(&1) == Enum.sort(primary_key)))

      Enum.flat_map([primary_key | identities], fn keys ->
        suffix = key_suffix(keys, primary_key)

        # Each key set needs its own point-in-time index, not just the primary key's. The
        # non-overlap trigger for a key set is a correlated subquery over that key, and
        # without a matching index it scans the whole table on every write. Measured on
        # 200k rows: `SEARCH other USING INDEX ... (slug=?)` with it,
        # `SCAN other` without.
        point_in_time_index(table, attribute, keys, suffix) ++
          [
            current_version_index(table, attribute, keys, suffix),
            no_overlap_trigger(table, attribute, keys, suffix, :insert),
            no_overlap_trigger(table, attribute, keys, suffix, :update)
          ]
      end)
    end

    # The primary key's statements keep their unsuffixed names, so an existing temporal
    # table does not see every one of them dropped and recreated.
    defp key_suffix(keys, primary_key) do
      if Enum.sort(keys) == Enum.sort(primary_key), do: "", else: "_" <> Enum.join(keys, "_")
    end

    defp point_in_time_index(_table, _attribute, [], _suffix), do: []

    defp point_in_time_index(table, attribute, keys, suffix) do
      name = "#{table}_#{attribute}_pit#{suffix}"
      columns = Enum.map_join(keys, ", ", &quote_name/1)

      %{
        name: String.to_atom(name),
        code?: false,
        up:
          "CREATE INDEX #{quote_name(name)} ON #{quote_name(table)} " <>
            "(#{columns}, #{lower(attribute)});",
        down: "DROP INDEX IF EXISTS #{quote_name(name)};"
      }
      |> List.wrap()
    end

    defp current_version_index(table, attribute, keys, suffix) do
      name = "#{table}_#{attribute}_current#{suffix}"
      columns = Enum.map_join(keys, ", ", &quote_name/1)

      %{
        name: String.to_atom(name),
        code?: false,
        up:
          "CREATE UNIQUE INDEX #{quote_name(name)} ON #{quote_name(table)} " <>
            "(#{columns}) WHERE #{upper(attribute)} IS NULL;",
        down: "DROP INDEX IF EXISTS #{quote_name(name)};"
      }
    end

    defp no_overlap_trigger(table, attribute, keys, suffix, event) do
      name = "#{table}_#{attribute}_no_overlap#{suffix}_#{event}"

      # `IS` rather than `=` so a nullable key column compares as a value. With `=` the
      # comparison would be NULL and the row would be found not to overlap anything.
      key_match =
        Enum.map_join(keys, "\n        AND ", fn key ->
          "other.#{quote_name(key)} IS NEW.#{quote_name(key)}"
        end)

      # On an insert the row has no rowid yet, so `other.rowid <> NEW.rowid` is NULL, the
      # whole conjunction is NULL, and the trigger silently never fires. An update does
      # need it, or the row being updated is found to overlap itself.
      self_match =
        case event do
          :insert -> ""
          :update -> "\n        AND other.rowid <> NEW.rowid"
        end

      %{
        name: String.to_atom(name),
        code?: false,
        up: """
        CREATE TRIGGER #{quote_name(name)}
        BEFORE #{String.upcase(to_string(event))} ON #{quote_name(table)}
        BEGIN
          SELECT RAISE(ABORT, '#{attribute} overlaps an existing period')
          WHERE EXISTS (
            SELECT 1 FROM #{quote_name(table)} AS other
            WHERE #{key_match}#{self_match}
              AND (#{new(attribute, "upper")} IS NULL
                   OR #{other(attribute, "lower")} < #{new(attribute, "upper")})
              AND (#{other(attribute, "upper")} IS NULL
                   OR #{other(attribute, "upper")} > #{new(attribute, "lower")})
          );
        END;
        """,
        down: "DROP TRIGGER IF EXISTS #{quote_name(name)};"
      }
    end

    defp lower(attribute), do: "json_extract(#{quote_name(attribute)}, '$.lower')"
    defp upper(attribute), do: "json_extract(#{quote_name(attribute)}, '$.upper')"
    defp new(attribute, bound), do: "json_extract(NEW.#{quote_name(attribute)}, '$.#{bound}')"
    defp other(attribute, bound), do: "json_extract(other.#{quote_name(attribute)}, '$.#{bound}')"

    defp quote_name(name) do
      escaped = name |> to_string() |> String.replace("\"", "\"\"")
      "\"" <> escaped <> "\""
    end
  else
    @doc "The statements for `resource`, or `[]` when it is not temporal."
    def statements(_resource), do: []
  end
end
