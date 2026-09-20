# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo.Migrations.AddPlansTable do
  use Ecto.Migration

  # Built by applying what `AshSqlite.Temporal.Migration.statements/1` emits for
  # `AshSqlite.Test.Plan`, which the temporal suite asserts against directly.
  def up do
    execute("""
    CREATE TABLE plans (
      id INTEGER NOT NULL,
      slug TEXT NOT NULL,
      price INTEGER DEFAULT 0,
      valid_at TEXT NOT NULL
    )
    """)

    for {suffix, keys} <- [{"", "id"}, {"_slug", "slug"}] do
      execute("""
      CREATE INDEX plans_valid_at_pit#{suffix}
      ON plans (#{keys}, json_extract(valid_at, '$.lower'))
      """)

      execute("""
      CREATE UNIQUE INDEX plans_valid_at_current#{suffix}
      ON plans (#{keys}) WHERE json_extract(valid_at, '$.upper') IS NULL
      """)

      for {name, event, self_clause} <- [
            {"insert", "INSERT", ""},
            {"update", "UPDATE", "AND other.rowid <> NEW.rowid"}
          ] do
        execute("""
        CREATE TRIGGER plans_valid_at_no_overlap#{suffix}_#{name}
        BEFORE #{event} ON plans
        BEGIN
          SELECT RAISE(ABORT, 'valid_at overlaps an existing period')
          WHERE EXISTS (
            SELECT 1 FROM plans AS other
            WHERE other.#{keys} IS NEW.#{keys}
              #{self_clause}
              AND (json_extract(NEW.valid_at, '$.upper') IS NULL
                   OR json_extract(other.valid_at, '$.lower') < json_extract(NEW.valid_at, '$.upper'))
              AND (json_extract(other.valid_at, '$.upper') IS NULL
                   OR json_extract(other.valid_at, '$.upper') > json_extract(NEW.valid_at, '$.lower'))
          );
        END
        """)
      end
    end
  end

  def down do
    for suffix <- ["_slug", ""], name <- ["update", "insert"] do
      execute("DROP TRIGGER IF EXISTS plans_valid_at_no_overlap#{suffix}_#{name}")
    end

    for suffix <- ["_slug", ""] do
      execute("DROP INDEX IF EXISTS plans_valid_at_current#{suffix}")
      execute("DROP INDEX IF EXISTS plans_valid_at_pit#{suffix}")
    end

    execute("DROP TABLE IF EXISTS plans")
  end
end
