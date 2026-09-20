# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo.Migrations.AddSubscriptionsTable do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE subscriptions (
      id INTEGER NOT NULL,
      tier TEXT,
      seats INTEGER DEFAULT 0,
      activated_at TEXT_DATETIME,
      valid_at TEXT NOT NULL
    )
    """)

    execute("""
    CREATE INDEX subscriptions_valid_at_pit
    ON subscriptions (id, json_extract(valid_at, '$.lower'))
    """)

    execute("""
    CREATE UNIQUE INDEX subscriptions_valid_at_current
    ON subscriptions (id) WHERE json_extract(valid_at, '$.upper') IS NULL
    """)

    # The insert trigger must not exclude NEW.rowid. On an insert the row has no
    # rowid yet, so `other.rowid <> NEW.rowid` is NULL, the whole conjunction is
    # NULL, and the trigger silently never fires. The update trigger does need it,
    # or a row would be found to overlap itself.
    for {name, event, self_clause} <- [
          {"insert", "INSERT", ""},
          {"update", "UPDATE", "AND other.rowid <> NEW.rowid"}
        ] do
      execute("""
      CREATE TRIGGER subscriptions_valid_at_no_overlap_#{name}
      BEFORE #{event} ON subscriptions
      BEGIN
        SELECT RAISE(ABORT, 'valid_at overlaps an existing period')
        WHERE EXISTS (
          SELECT 1 FROM subscriptions AS other
          WHERE other.id IS NEW.id
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

  def down do
    execute("DROP TRIGGER IF EXISTS subscriptions_valid_at_no_overlap_update")
    execute("DROP TRIGGER IF EXISTS subscriptions_valid_at_no_overlap_insert")
    execute("DROP INDEX IF EXISTS subscriptions_valid_at_current")
    execute("DROP INDEX IF EXISTS subscriptions_valid_at_pit")
    execute("DROP TABLE IF EXISTS subscriptions")
  end
end
