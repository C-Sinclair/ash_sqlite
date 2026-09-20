# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# The temporal DSL is unreleased. Skip these entirely when ash does not have it,
# rather than failing to compile against a released version.
if Code.ensure_loaded?(Ash.Temporal) do
  defmodule AshSqlite.Test.Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshSqlite.Test.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("subscriptions")
      repo(AshSqlite.TransactionTestRepo)
    end

    temporal do
      strategy(:context)
      attribute(:valid_at)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:tier, :string, public?: true)
      attribute(:seats, :integer, default: 0, public?: true)
      attribute(:activated_at, :utc_datetime_usec, public?: true)

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

    actions do
      defaults([:read, :destroy, create: [:id, :tier, :seats, :activated_at]])

      create :upsert_tier do
        accept([:id, :tier, :seats])
        upsert?(true)
        upsert_identity(:id)
        upsert_fields([:tier, :seats])
      end

      update :change_tier do
        require_atomic?(true)
        accept([:tier])
      end

      update :change_tier_nonatomic do
        require_atomic?(false)
        accept([:tier])
      end

      update :add_seat do
        require_atomic?(true)
        change(atomic_update(:seats, expr(seats + 1)))
      end

      destroy :expire do
        require_atomic?(true)
      end
    end

    identities do
      identity(:id, [:id])
    end
  end
end
