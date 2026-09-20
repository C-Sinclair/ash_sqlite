# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# The temporal DSL is unreleased. Skip this entirely when ash does not have it.
if Code.ensure_loaded?(Ash.Temporal) do
  defmodule AshSqlite.Test.Plan do
    @moduledoc """
    A temporal resource with an identity that is not its primary key.

    Postgres writes such an identity as `UNIQUE (slug, valid_at WITHOUT OVERLAPS)`, so
    the slug is unique *at every instant* rather than unique in the table. This resource
    exists to check that the partial index and trigger pair `AshSqlite.Temporal.Migration`
    generates per identity reach the same guarantee.
    """
    use Ash.Resource,
      domain: AshSqlite.Test.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("plans")
      repo(AshSqlite.TransactionTestRepo)
    end

    temporal do
      strategy(:context)
      attribute(:valid_at)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:slug, :string, allow_nil?: false, public?: true)
      attribute(:price, :integer, default: 0, public?: true)

      attribute(:valid_at, Ash.Type.Range,
        allow_nil?: false,
        constraints: [
          inner_type: :datetime,
          inner_constraints: [precision: :microsecond],
          lower: [inclusive?: true],
          upper: [inclusive?: false]
        ],
        public?: true
      )
    end

    identities do
      identity(:unique_slug, [:slug])
    end

    actions do
      defaults([:read, :destroy, create: [:id, :slug, :price]])

      update :change_price do
        require_atomic?(true)
        accept([:price])
      end
    end
  end
end
