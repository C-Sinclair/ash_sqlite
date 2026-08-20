# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.TransactionalAccount do
  @moduledoc """
  Shares the `accounts` table with `AshSqlite.Test.Account`, with transactions on.

  Sharing the table is the point: the two resources differ only in `transactions?`,
  so a test can show that the same action either rolls back or does not.
  """
  use Ash.Resource, domain: AshSqlite.Test.Domain, data_layer: AshSqlite.DataLayer

  actions do
    default_accept(:*)
    defaults([:create, :read, :update, :destroy])

    create :create_then_fail do
      accept([:is_active])

      change(
        after_action(fn _changeset, _record, _context ->
          {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :is_active, message: "no")}
        end)
      )
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:is_active, :boolean, public?: true)
  end

  sqlite do
    table("accounts")
    repo(AshSqlite.TestRepo)
    transactions?(true)
  end
end
