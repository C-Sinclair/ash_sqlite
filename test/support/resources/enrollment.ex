# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# The temporal DSL is unreleased. Skip this entirely when ash does not have it.
if Code.ensure_loaded?(Ash.Temporal) do
  defmodule AshSqlite.Test.Enrollment do
    @moduledoc """
    A non-temporal resource pointing at a temporal one.

    `temporal_keys {nil, :valid_at}` is how a relationship declares that only its
    destination keeps periods. `Ash.Resource.Transformers.AddTemporalRelationshipFilters`
    bakes its `range_overlaps(parent(source), destination)` filter only when *both* sides
    are given, so this shape needs no `parent/1` and therefore no lateral join, which
    SQLite has no equivalent of.

    No database foreign key is generated for the relationship. A temporal table has no
    unique key for one to point at, and SQLite rejects every insert into the child with
    "foreign key mismatch" if one is declared anyway.
    """
    use Ash.Resource,
      domain: AshSqlite.Test.Domain,
      data_layer: AshSqlite.DataLayer

    sqlite do
      table("enrollments")
      repo(AshSqlite.TransactionTestRepo)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:plan_id, :integer, public?: true)
    end

    relationships do
      belongs_to :plan, AshSqlite.Test.Plan do
        source_attribute(:plan_id)
        destination_attribute(:id)
        define_attribute?(false)
        attribute_type(:integer)
        temporal_keys({nil, :valid_at})
        public?(true)
      end
    end

    actions do
      defaults([:read, :destroy, create: [:id, :plan_id]])
    end
  end
end
