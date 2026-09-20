# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TestRepo.Migrations.AddEnrollmentsTable do
  use Ecto.Migration

  # `plan_id` carries no foreign key. Its destination is temporal and so has no unique
  # key to reference; SQLite would reject every insert here with "foreign key mismatch".
  def up do
    execute("""
    CREATE TABLE enrollments (
      id INTEGER NOT NULL PRIMARY KEY,
      plan_id INTEGER
    )
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS enrollments")
  end
end
