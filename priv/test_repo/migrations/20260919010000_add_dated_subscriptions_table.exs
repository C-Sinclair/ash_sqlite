# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo.Migrations.AddDatedSubscriptionsTable do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE dated_subscriptions (
      id INTEGER NOT NULL,
      tier TEXT,
      valid_on TEXT NOT NULL
    )
    """)

    execute("""
    CREATE INDEX dated_subscriptions_valid_on_pit
    ON dated_subscriptions (id, json_extract(valid_on, '$.lower'))
    """)

    execute("""
    CREATE UNIQUE INDEX dated_subscriptions_valid_on_current
    ON dated_subscriptions (id) WHERE json_extract(valid_on, '$.upper') IS NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS dated_subscriptions_valid_on_current")
    execute("DROP INDEX IF EXISTS dated_subscriptions_valid_on_pit")
    execute("DROP TABLE IF EXISTS dated_subscriptions")
  end
end
