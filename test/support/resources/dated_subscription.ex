# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# The temporal DSL is unreleased. Skip this entirely when ash does not have it.
if Code.ensure_loaded?(Ash.Temporal) do
  defmodule AshSqlite.Test.DatedSubscription do
    @moduledoc """
    A temporal resource whose period is a `:date` rather than a `:datetime`.

    `Ash.Type.Range` allows `:date`, `:integer`, `:naive_datetime` and `:datetime`
    bounds, and only `:datetime` has a `DateTime.compare/2`. This resource is here so
    the split is exercised on a bound type that does not.
    """
    use Ash.Resource,
      domain: AshSqlite.Test.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("dated_subscriptions")
      repo(AshSqlite.TransactionTestRepo)
    end

    temporal do
      strategy(:context)
      attribute(:valid_on)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:tier, :string, public?: true)

      attribute(:valid_on, Ash.Type.Range,
        allow_nil?: false,
        constraints: [
          inner_type: :date,
          lower: [inclusive?: true],
          upper: [inclusive?: false]
        ],
        public?: true
      )
    end

    actions do
      defaults([:read, :destroy, create: [:id, :tier]])

      update :change_tier do
        require_atomic?(true)
        accept([:tier])
      end
    end
  end
end
