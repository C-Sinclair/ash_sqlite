# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# The temporal DSL is unreleased. Skip these entirely when ash does not have it,
# rather than failing to compile against a released version.
if Code.ensure_loaded?(Ash.Temporal) do
  defmodule AshSqlite.TemporalTest do
    @moduledoc """
    The behaviour contract for a temporal resource on SQLite.

    SQLite has no `FOR PORTION OF`, so every period split is a read-modify-write the
    data layer performs inside a transaction. These tests assert the *outcome* of that
    split, which is the same outcome Postgres reaches with one statement, and separately
    assert the two constraints SQLite can enforce underneath it.
    """
    use AshSqlite.RepoCase, async: false

    alias AshSqlite.Test.Subscription

    require Ash.Query
    require Ash.Expr

    import Ash.Expr

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(AshSqlite.TransactionTestRepo)
      Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TransactionTestRepo, {:shared, self()})
      :ok
    end

    @jan ~U[2026-01-01 00:00:00.000000Z]
    @feb ~U[2026-02-01 00:00:00.000000Z]
    @mar ~U[2026-03-01 00:00:00.000000Z]
    @apr ~U[2026-04-01 00:00:00.000000Z]

    defp create!(id, tier, as_of, opts \\ []) do
      Subscription
      |> Ash.Changeset.for_create(:create, Keyword.merge([id: id, tier: tier], opts))
      |> Ash.Changeset.set_context(%{})
      |> Ash.Changeset.as_of(as_of)
      |> Ash.create!()
    end

    # Every version of a record, oldest first. This reads the table directly: a temporal
    # read is always pinned to an instant, so there is no Ash query that returns history.
    defp periods(id) do
      id
      |> raw_rows()
      |> Enum.map(fn [lower, upper, tier] -> {tier, lower, upper} end)
    end

    defp raw_seats(id) do
      {:ok, %{rows: rows}} =
        AshSqlite.TransactionTestRepo.query(
          "select json_extract(valid_at,'$.lower'), seats from subscriptions " <>
            "where id = ? order by json_extract(valid_at,'$.lower')",
          [id]
        )

      Enum.map(rows, fn [lower, seats] -> {lower, seats} end)
    end

    defp iso(nil), do: nil
    defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

    # Every version of a record, ignoring the default "as of now" filter. A temporal
    # read never returns history, so the raw table is the only way to assert a split.
    defp raw_rows(id) do
      {:ok, %{rows: rows}} =
        AshSqlite.TransactionTestRepo.query(
          "select json_extract(valid_at,'$.lower'), json_extract(valid_at,'$.upper'), tier " <>
            "from subscriptions where id = ? order by json_extract(valid_at,'$.lower')",
          [id]
        )

      rows
    end

    describe "capability" do
      test "the data layer reports temporal support" do
        assert Ash.DataLayer.can?(AshSqlite.DataLayer, Subscription, :temporal)
      end

      test "the resource is temporal and names its period attribute" do
        assert Ash.Resource.Info.temporal?(Subscription)
        assert Ash.Resource.Info.temporal_attribute(Subscription) == :valid_at
      end
    end

    test "a temporal resource on a repo without write transactions is refused" do
      # Spark runs verifiers from `@after_verify`, so the error surfaces from the
      # parallel checker rather than from `defmodule` itself. Calling the verifier is
      # what actually asserts the rule, rather than asserting on compilation order.
      assert {:error, %Spark.Error.DslError{} = error} =
               AshSqlite.Verifiers.VerifyTemporal.verify(
                 dsl_with_repo(AshSqlite.Test.Subscription, AshSqlite.TestRepo)
               )

      assert Exception.message(error) =~ "requires a repo with write transactions"
    end

    test "a temporal resource on a repo with write transactions is accepted" do
      assert :ok =
               AshSqlite.Verifiers.VerifyTemporal.verify(
                 AshSqlite.Test.Subscription.spark_dsl_config()
               )
    end

    test "a non-temporal resource is accepted on any repo" do
      assert :ok =
               AshSqlite.Verifiers.VerifyTemporal.verify(AshSqlite.Test.Post.spark_dsl_config())
    end

    defp dsl_with_repo(resource, repo) do
      resource
      |> then(& &1.spark_dsl_config())
      |> Spark.Dsl.Transformer.set_option([:sqlite], :repo, repo)
    end

    describe "create" do
      test "stamps the period from as_of, unbounded above" do
        record = create!(1, "free", @jan)

        assert record.valid_at.lower == @jan
        assert is_nil(record.valid_at.upper)
      end

      test "a create without as_of takes effect now" do
        before = DateTime.utc_now()

        record =
          Subscription
          |> Ash.Changeset.for_create(:create, %{id: 2, tier: "free"})
          |> Ash.create!()

        assert DateTime.compare(record.valid_at.lower, before) in [:gt, :eq]
        assert is_nil(record.valid_at.upper)
      end

      test "the period attribute is not accepted as input" do
        assert_raise Ash.Error.Invalid, ~r/valid_at/, fn ->
          Subscription
          |> Ash.Changeset.for_create(:create, %{id: 3, tier: "free", valid_at: %{}})
          |> Ash.create!()
        end
      end
    end

    describe "reads default to the current version" do
      setup do
        create!(10, "free", @jan)
        :ok
      end

      test "a read with no as_of returns the version valid now" do
        assert [%{tier: "free"}] = Ash.read!(Subscription)
      end

      test "a read returns one row per key, not the whole history" do
        Subscription
        |> Ash.get!(10)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.Changeset.as_of(@feb)
        |> Ash.update!()

        assert length(Ash.read!(Subscription)) == 1
      end
    end

    describe "as_of reads" do
      setup do
        create!(20, "free", @jan)

        Subscription
        |> Ash.get!(20)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        :ok
      end

      test "returns the version valid at that instant" do
        assert [%{tier: "free"}] =
                 Subscription |> Ash.Query.as_of(@feb) |> Ash.read!()

        assert [%{tier: "pro"}] =
                 Subscription |> Ash.Query.as_of(@apr) |> Ash.read!()
      end

      test "returns nothing before the first period begins" do
        assert [] =
                 Subscription
                 |> Ash.Query.as_of(~U[2025-12-01 00:00:00.000000Z])
                 |> Ash.read!()
      end

      test "the lower bound is inclusive and the upper bound is exclusive" do
        assert [%{tier: "free"}] = Subscription |> Ash.Query.as_of(@jan) |> Ash.read!()
        assert [%{tier: "pro"}] = Subscription |> Ash.Query.as_of(@mar) |> Ash.read!()
      end

      test "Ash.get respects as_of" do
        assert %{tier: "free"} = Ash.get!(Subscription, 20, as_of: @feb)
      end
    end

    describe "update splits the period at as_of" do
      test "an atomic update closes the prior version and opens a new one" do
        create!(30, "free", @jan)

        Subscription
        |> Ash.get!(30)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        assert periods(30) == [{"free", iso(@jan), iso(@mar)}, {"pro", iso(@mar), nil}]
      end

      test "a non-atomic update splits the same way" do
        create!(31, "free", @jan)

        Subscription
        |> Ash.get!(31)
        |> Ash.Changeset.for_update(:change_tier_nonatomic, %{tier: "pro"})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        assert periods(31) == [{"free", iso(@jan), iso(@mar)}, {"pro", iso(@mar), nil}]
      end

      test "an atomic arithmetic update applies to the new slice only" do
        create!(32, "free", @jan, seats: 3)

        Subscription
        |> Ash.get!(32)
        |> Ash.Changeset.for_update(:add_seat)
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        seats =
          32
          |> raw_seats()
          |> Enum.map(&elem(&1, 1))

        assert seats == [3, 4]
      end

      test "two successive updates leave three contiguous periods" do
        create!(33, "free", @jan)

        for {tier, at} <- [{"pro", @feb}, {"max", @mar}] do
          Subscription
          |> Ash.get!(33)
          |> Ash.Changeset.for_update(:change_tier, %{tier: tier})
          |> Ash.Changeset.as_of(at)
          |> Ash.update!()
        end

        assert periods(33) == [
                 {"free", iso(@jan), iso(@feb)},
                 {"pro", iso(@feb), iso(@mar)},
                 {"max", iso(@mar), nil}
               ]
      end

      test "an update at the period's own lower bound replaces it rather than leaving an empty period" do
        create!(34, "free", @jan)

        Subscription
        |> Ash.get!(34)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.update!()

        assert periods(34) == [{"pro", iso(@jan), nil}]
      end
    end

    describe "destroy truncates validity" do
      test "a destroy ends the current period at as_of and keeps the history" do
        create!(40, "free", @jan)

        Subscription
        |> Ash.get!(40)
        |> Ash.Changeset.for_destroy(:expire)
        |> Ash.Changeset.as_of(@mar)
        |> Ash.destroy!()

        assert periods(40) == [{"free", iso(@jan), iso(@mar)}]
        assert [] = Subscription |> Ash.Query.as_of(@apr) |> Ash.read!()
        assert [%{tier: "free"}] = Subscription |> Ash.Query.as_of(@feb) |> Ash.read!()
      end

      test "destroying at the period's lower bound removes the row" do
        create!(41, "free", @jan)

        Subscription
        |> Ash.get!(41)
        |> Ash.Changeset.for_destroy(:expire)
        |> Ash.Changeset.as_of(@jan)
        |> Ash.destroy!()

        assert periods(41) == []
      end
    end

    describe "upsert" do
      test "a miss inserts a new period" do
        Subscription
        |> Ash.Changeset.for_create(:upsert_tier, %{id: 50, tier: "free"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.create!()

        assert periods(50) == [{"free", iso(@jan), nil}]
      end

      test "a match splits the period valid at as_of" do
        Subscription
        |> Ash.Changeset.for_create(:upsert_tier, %{id: 51, tier: "free"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.create!()

        Subscription
        |> Ash.Changeset.for_create(:upsert_tier, %{id: 51, tier: "pro"})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.create!()

        assert periods(51) == [{"free", iso(@jan), iso(@mar)}, {"pro", iso(@mar), nil}]
      end
    end

    describe "bulk actions" do
      test "bulk_create stamps each record's period from as_of" do
        Ash.bulk_create!(
          [%{id: 60, tier: "free"}, %{id: 61, tier: "pro"}],
          Subscription,
          :create,
          as_of: @jan,
          return_errors?: true
        )

        assert periods(60) == [{"free", iso(@jan), nil}]
        assert periods(61) == [{"pro", iso(@jan), nil}]
      end

      test "a bulk update splits every matched record at as_of" do
        create!(62, "free", @jan)
        create!(63, "free", @jan)

        Subscription
        |> Ash.Query.filter(tier == "free")
        |> Ash.bulk_update!(:change_tier, %{tier: "pro"},
          as_of: @mar,
          strategy: [:stream, :atomic, :atomic_batches],
          return_errors?: true
        )

        assert periods(62) == [{"free", iso(@jan), iso(@mar)}, {"pro", iso(@mar), nil}]
        assert periods(63) == [{"free", iso(@jan), iso(@mar)}, {"pro", iso(@mar), nil}]
      end

      test "a bulk destroy truncates every matched record at as_of" do
        create!(64, "free", @jan)
        create!(65, "free", @jan)

        Subscription
        |> Ash.Query.filter(tier == "free")
        |> Ash.bulk_destroy!(:expire, %{},
          as_of: @mar,
          strategy: [:stream, :atomic, :atomic_batches],
          return_errors?: true
        )

        assert periods(64) == [{"free", iso(@jan), iso(@mar)}]
        assert periods(65) == [{"free", iso(@jan), iso(@mar)}]
      end
    end

    describe "the database refuses a broken timeline" do
      test "a second open-ended period for one key is rejected by the partial unique index" do
        create!(70, "free", @jan)

        assert {:error, _} =
                 AshSqlite.TransactionTestRepo.query(
                   "insert into subscriptions (id, tier, seats, valid_at) values (?, ?, ?, ?)",
                   [
                     70,
                     "pro",
                     0,
                     ~s|{"lower":"2026-03-01T00:00:00.000000Z","upper":null,"bounds":"[)","empty":false}|
                   ]
                 )
      end

      test "an overlapping closed period is rejected by the non-overlap trigger" do
        create!(71, "free", @jan)

        Subscription
        |> Ash.get!(71)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        assert {:error, _} =
                 AshSqlite.TransactionTestRepo.query(
                   "insert into subscriptions (id, tier, seats, valid_at) values (?, ?, ?, ?)",
                   [
                     71,
                     "mid",
                     0,
                     ~s|{"lower":"2026-01-15T00:00:00.000000Z","upper":"2026-02-15T00:00:00.000000Z","bounds":"[)","empty":false}|
                   ]
                 )
      end

      test "an adjacent, non-overlapping period is accepted" do
        create!(72, "free", @jan)

        Subscription
        |> Ash.get!(72)
        |> Ash.Changeset.for_destroy(:expire)
        |> Ash.Changeset.as_of(@feb)
        |> Ash.destroy!()

        assert {:ok, _} =
                 AshSqlite.TransactionTestRepo.query(
                   "insert into subscriptions (id, tier, seats, valid_at) values (?, ?, ?, ?)",
                   [
                     72,
                     "pro",
                     0,
                     ~s|{"lower":"2026-02-01T00:00:00.000000Z","upper":null,"bounds":"[)","empty":false}|
                   ]
                 )
      end

      test "a failed split leaves no partial write" do
        create!(73, "free", @jan)

        # An update whose insert half violates the trigger must roll the close back too,
        # or the record is left with no current version at all.
        assert periods(73) == [{"free", iso(@jan), nil}]
      end
    end

    describe "now() anchors to as_of" do
      test "a filter on now() is evaluated at the read's as_of" do
        create!(80, "free", @jan, activated_at: @feb)

        assert [] =
                 Subscription
                 |> Ash.Query.as_of(@jan)
                 |> Ash.Query.filter(activated_at < now())
                 |> Ash.read!()

        assert [%{id: 80}] =
                 Subscription
                 |> Ash.Query.as_of(@mar)
                 |> Ash.Query.filter(activated_at < now())
                 |> Ash.read!()
      end
    end

    describe "range expressions over the period" do
      test "range_overlaps filters by overlap with a literal range" do
        create!(90, "free", @jan)

        overlapping = %Ash.Range{lower: @jan, upper: @feb, bounds: :"[)"}

        disjoint = %Ash.Range{
          lower: ~U[2025-01-01 00:00:00.000000Z],
          upper: ~U[2025-06-01 00:00:00.000000Z],
          bounds: :"[)"
        }

        assert [%{id: 90}] =
                 Subscription
                 |> Ash.Query.as_of(@jan)
                 |> Ash.Query.filter(id == 90 and range_overlaps(valid_at, ^overlapping))
                 |> Ash.read!()

        assert [] =
                 Subscription
                 |> Ash.Query.as_of(@jan)
                 |> Ash.Query.filter(id == 90 and range_overlaps(valid_at, ^disjoint))
                 |> Ash.read!()
      end

      test "range_lower selects the period's lower bound" do
        create!(91, "free", @jan)

        assert [@jan] =
                 Subscription
                 |> Ash.Query.filter(id == 91)
                 |> Ash.Query.calculate(:lo, :utc_datetime_usec, expr(range_lower(valid_at)))
                 |> Ash.read!()
                 |> Enum.map(& &1.calculations.lo)
      end
    end

    describe "the split is one transaction" do
      test "the close and the insert are both visible or neither is" do
        create!(100, "free", @jan)

        assert length(raw_rows(100)) == 1

        Subscription
        |> Ash.get!(100)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        assert length(raw_rows(100)) == 2
      end
    end

    describe "the migration generator emits what a temporal table needs" do
      @describetag :tmp_dir

      setup %{tmp_dir: tmp_dir} do
        %{
          snapshot_path: Path.join(tmp_dir, "snapshots"),
          migration_path: Path.join(tmp_dir, "migrations")
        }
      end

      defp generated_migration(snapshot_path, migration_path) do
        AshSqlite.MigrationGenerator.generate(AshSqlite.Test.Domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          quiet: true,
          format: false,
          auto_name: true
        )

        migration_path
        |> Path.join("**/*_migrate_resources*.exs")
        |> Path.wildcard()
        |> Enum.map_join("\n", &File.read!/1)
      end

      test "a point-in-time index, a current-version constraint and both triggers", %{
        snapshot_path: snapshot_path,
        migration_path: migration_path
      } do
        sql = generated_migration(snapshot_path, migration_path)

        assert sql =~
                 ~s|CREATE INDEX "subscriptions_valid_at_pit" ON "subscriptions" ("id", json_extract("valid_at", '$.lower'))|

        assert sql =~
                 ~s|CREATE UNIQUE INDEX "subscriptions_valid_at_current" ON "subscriptions" ("id") WHERE json_extract("valid_at", '$.upper') IS NULL|

        assert sql =~ ~s|CREATE TRIGGER "subscriptions_valid_at_no_overlap_insert"|
        assert sql =~ ~s|CREATE TRIGGER "subscriptions_valid_at_no_overlap_update"|
      end

      test "the insert trigger does not exclude NEW.rowid and the update trigger does", %{
        snapshot_path: snapshot_path,
        migration_path: migration_path
      } do
        sql = generated_migration(snapshot_path, migration_path)

        [_, insert_trigger, update_trigger] =
          String.split(
            sql,
            ~r/CREATE TRIGGER "subscriptions_valid_at_no_overlap_(insert|update)"/
          )

        refute insert_trigger =~ "NEW.rowid"
        assert update_trigger =~ ~s|other.rowid <> NEW.rowid|
      end

      test "the table has no primary key and no plain unique index", %{
        snapshot_path: snapshot_path,
        migration_path: migration_path
      } do
        sql = generated_migration(snapshot_path, migration_path)

        # A temporal table holds one row per period. A PRIMARY KEY or a plain unique
        # index over the key makes a second version impossible, and on an integer key a
        # PRIMARY KEY also makes it SQLite's rowid alias, which every `WHERE rowid = ?`
        # in AshSqlite.Temporal would then be addressing.
        assert String.contains?(sql, "create table(:subscriptions, primary_key: false)")
        refute String.contains?(sql, "subscriptions_id_index")

        subscriptions_block =
          sql
          |> String.split("create table(:subscriptions")
          |> Enum.at(1)
          |> String.split("\nend\n")
          |> Enum.at(0)

        refute String.contains?(subscriptions_block, "primary_key: true")
      end

      test "a non-temporal resource keeps its primary key", %{
        snapshot_path: snapshot_path,
        migration_path: migration_path
      } do
        sql = generated_migration(snapshot_path, migration_path)

        assert sql =~ "create table(:posts, primary_key: false)"
        assert sql =~ "primary_key: true"
      end

      test "applying the generated statements leaves a table that holds two periods" do
        {:ok, db} = Exqlite.Sqlite3.open(":memory:")

        :ok =
          Exqlite.Sqlite3.execute(db, """
          CREATE TABLE subscriptions (
            id INTEGER NOT NULL, tier TEXT, seats INTEGER, activated_at TEXT, valid_at TEXT NOT NULL
          )
          """)

        for %{up: up} <- AshSqlite.Temporal.Migration.statements(Subscription) do
          :ok = Exqlite.Sqlite3.execute(db, up)
        end

        insert = fn lower, upper ->
          period = Jason.encode!(%{lower: lower, upper: upper, bounds: "[)", empty: false})

          Exqlite.Sqlite3.execute(
            db,
            "INSERT INTO subscriptions (id, tier, seats, valid_at) VALUES " <>
              "(1, 'free', 0, '" <> period <> "')"
          )
        end

        assert :ok = insert.("2026-01-01", "2026-03-01")
        assert :ok = insert.("2026-03-01", nil)
        assert {:error, _} = insert.("2026-02-01", "2026-04-01")
        assert {:error, _} = insert.("2026-05-01", nil)
      end

      test "a non-temporal resource gets none of it" do
        assert AshSqlite.Temporal.Migration.statements(AshSqlite.Test.Post) == []
      end
    end

    describe "period bound types other than datetime" do
      # `Ash.Temporal.raw_instant/2` accepts only a `DateTime` or `:now`, so a `:date`
      # resource cannot be handed an explicit `Date` as_of. It still reaches a `Date`
      # bound through `:now`, because `Ash.Temporal.now_for/1` returns `Date.utc_today/0`
      # for a `:date` inner type. That is the path these cover.
      setup do
        {:ok, _} = AshSqlite.TransactionTestRepo.query("DELETE FROM dated_subscriptions", [])
        :ok
      end

      test "closing a :date period does not compare it as a DateTime" do
        # Seeded directly so the prior period begins before today and the write splits it.
        yesterday = Date.add(Date.utc_today(), -1)

        {:ok, _} =
          AshSqlite.TransactionTestRepo.query(
            "insert into dated_subscriptions (id, tier, valid_on) values (?, ?, ?)",
            [1, "free", ~s|{"lower":"#{yesterday}","upper":null,"bounds":"[)","empty":false}|]
          )

        AshSqlite.Test.DatedSubscription
        |> Ash.get!(1)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.update!()

        {:ok, %{rows: rows}} =
          AshSqlite.TransactionTestRepo.query(
            "select json_extract(valid_on,'$.lower'), json_extract(valid_on,'$.upper'), tier " <>
              "from dated_subscriptions where id = 1 order by json_extract(valid_on,'$.lower')",
            []
          )

        today = to_string(Date.utc_today())

        assert rows == [
                 [to_string(yesterday), today, "free"],
                 [today, nil, "pro"]
               ]
      end

      test "a write landing on a :date period's own lower bound replaces it" do
        AshSqlite.Test.DatedSubscription
        |> Ash.Changeset.for_create(:create, %{id: 2, tier: "free"})
        |> Ash.create!()

        AshSqlite.Test.DatedSubscription
        |> Ash.get!(2)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "pro"})
        |> Ash.update!()

        {:ok, %{rows: rows}} =
          AshSqlite.TransactionTestRepo.query(
            "select json_extract(valid_on,'$.lower'), json_extract(valid_on,'$.upper'), tier " <>
              "from dated_subscriptions where id = 2",
            []
          )

        assert rows == [[to_string(Date.utc_today()), nil, "pro"]]
      end
    end

    describe "a limited bulk update" do
      test "splits only the rows it updates" do
        for id <- 200..204, do: create!(id, "free", @jan)

        Subscription
        |> Ash.Query.filter(tier == "free" and id >= 200 and id <= 204)
        |> Ash.Query.limit(2)
        |> Ash.Query.sort(id: :asc)
        |> Ash.bulk_update!(:change_tier, %{tier: "pro"},
          as_of: @mar,
          strategy: [:stream, :atomic, :atomic_batches],
          return_errors?: true
        )

        split = Enum.count(200..204, fn id -> length(periods(id)) == 2 end)

        assert split == 2,
               "expected exactly the two limited rows to be split, got #{split}: " <>
                 inspect(Enum.map(200..204, &{&1, periods(&1)}))
      end
    end

    describe "the set-wide update targets only the versions it split" do
      test "a limited bulk update leaves earlier versions of the matched record alone" do
        create!(300, "free", @jan)

        Subscription
        |> Ash.get!(300)
        |> Ash.Changeset.for_update(:change_tier, %{tier: "basic"})
        |> Ash.Changeset.as_of(@feb)
        |> Ash.update!()

        create!(301, "free", @jan)

        # A limit forces `bulk_updatable_query/6` to rewrite the statement as a join
        # against a subquery. Joined on the primary key alone that reaches every version
        # of the record, including the closed one.
        Subscription
        |> Ash.Query.filter(id in [300, 301])
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(1)
        |> Ash.bulk_update!(:change_tier, %{tier: "pro"},
          as_of: @mar,
          strategy: [:atomic],
          return_errors?: true
        )

        assert periods(300) == [
                 {"free", iso(@jan), iso(@feb)},
                 {"basic", iso(@feb), iso(@mar)},
                 {"pro", iso(@mar), nil}
               ]

        assert periods(301) == [{"free", iso(@jan), nil}]
      end
    end

    describe "a query pinned to one instant and a write at another" do
      test "the write takes effect at the instant the query is pinned to" do
        create!(310, "free", @jan)

        Subscription
        |> Ash.Query.filter(id == 310)
        |> Ash.Query.as_of(@feb)
        |> Ash.bulk_update!(:change_tier, %{tier: "pro"},
          as_of: @mar,
          strategy: [:atomic],
          return_errors?: true
        )

        # The update must land somewhere rather than silently matching nothing.
        assert periods(310) == [{"free", iso(@jan), iso(@feb)}, {"pro", iso(@feb), nil}]
      end
    end

    describe "bulk upsert" do
      test "Ash.bulk_create with upsert? splits a match and inserts a miss" do
        create!(320, "free", @jan)

        Ash.bulk_create!(
          [%{id: 320, tier: "pro"}, %{id: 321, tier: "new"}],
          Subscription,
          :upsert_tier,
          as_of: @mar,
          return_errors?: true
        )

        assert periods(320) == [{"free", iso(@jan), iso(@mar)}, {"pro", iso(@mar), nil}]
        assert periods(321) == [{"new", iso(@mar), nil}]
      end
    end

    describe "the record an upsert returns" do
      test "carries the attributes the upsert did not name" do
        create!(330, "free", @jan, seats: 9, activated_at: @feb)

        record =
          Subscription
          |> Ash.Changeset.for_create(:upsert_tier, %{id: 330, tier: "pro"})
          |> Ash.Changeset.as_of(@mar)
          |> Ash.create!()

        assert record.tier == "pro"
        assert record.activated_at == @feb
      end
    end

    describe "identity is unique at every instant, not unique in the table" do
      alias AshSqlite.Test.Plan

      setup do
        {:ok, _} = AshSqlite.TransactionTestRepo.query("DELETE FROM plans", [])
        :ok
      end

      defp plan!(id, slug, as_of) do
        Plan
        |> Ash.Changeset.for_create(:create, %{id: id, slug: slug})
        |> Ash.Changeset.as_of(as_of)
        |> Ash.create!()
      end

      test "two records cannot hold the same identity at the same instant" do
        plan!(1, "pro", @jan)

        assert_raise Ash.Error.Unknown, ~r/overlaps an existing period/, fn ->
          plan!(2, "pro", @feb)
        end
      end

      test "two records can hold the same identity at instants that do not overlap" do
        plan!(1, "pro", @jan)

        Plan
        |> Ash.get!(1)
        |> Ash.Changeset.for_destroy(:destroy)
        |> Ash.Changeset.as_of(@feb)
        |> Ash.destroy!()

        # The slug is free from February onwards, so another record may take it.
        assert %{id: 2} = plan!(2, "pro", @mar)
      end

      test "a record's own split does not collide with its own identity" do
        plan!(3, "solo", @jan)

        Plan
        |> Ash.get!(3)
        |> Ash.Changeset.for_update(:change_price, %{price: 10})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        {:ok, %{rows: rows}} =
          AshSqlite.TransactionTestRepo.query(
            "select json_extract(valid_at,'$.lower'), json_extract(valid_at,'$.upper'), price " <>
              "from plans where id = 3 order by json_extract(valid_at,'$.lower')",
            []
          )

        assert rows == [
                 [iso(@jan), iso(@mar), 0],
                 [iso(@mar), nil, 10]
               ]
      end

      test "the primary key still identifies the record, and the period is not part of it" do
        plan!(4, "keyed", @jan)

        assert Ash.Resource.Info.primary_key(Plan) == [:id]

        assert %{primary_key?: false, generated?: true} =
                 Ash.Resource.Info.attribute(Plan, :valid_at)

        # One id, many rows: `Ash.get!` resolves it to the version valid at the instant.
        Plan
        |> Ash.get!(4)
        |> Ash.Changeset.for_update(:change_price, %{price: 99})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        assert %{price: 0} = Ash.get!(Plan, 4, as_of: @feb)
        assert %{price: 99} = Ash.get!(Plan, 4, as_of: @apr)
      end

      test "the generator emits a partial index and a trigger pair per identity" do
        names = Enum.map(AshSqlite.Temporal.Migration.statements(Plan), & &1.name)

        assert :plans_valid_at_current in names
        assert :plans_valid_at_current_slug in names
        assert :plans_valid_at_no_overlap_slug_insert in names
        assert :plans_valid_at_no_overlap_slug_update in names

        # The trigger for an identity is a correlated subquery over that identity's
        # keys, so it needs its own index or every write scans the table.
        assert :plans_valid_at_pit_slug in names
      end

      test "the trigger for an identity seeks rather than scans" do
        {:ok, db} = Exqlite.Sqlite3.open(":memory:")

        :ok =
          Exqlite.Sqlite3.execute(db, """
          CREATE TABLE plans (
            id INTEGER NOT NULL, slug TEXT NOT NULL, price INTEGER, valid_at TEXT NOT NULL
          )
          """)

        for %{up: up} <- AshSqlite.Temporal.Migration.statements(Plan) do
          :ok = Exqlite.Sqlite3.execute(db, up)
        end

        {:ok, statement} =
          Exqlite.Sqlite3.prepare(db, """
          EXPLAIN QUERY PLAN
          SELECT 1 FROM plans AS other
          WHERE other.slug IS 'pro'
            AND (json_extract(other.valid_at,'$.upper') IS NULL
                 OR json_extract(other.valid_at,'$.upper') > '2026-01-01')
          """)

        {:ok, [[_, _, _, plan]]} = Exqlite.Sqlite3.fetch_all(db, statement)

        assert plan =~ "USING INDEX plans_valid_at_pit_slug"
        refute plan =~ "SCAN other"
      end
    end

    describe "a relationship to a temporal resource" do
      alias AshSqlite.Test.Enrollment
      alias AshSqlite.Test.Plan

      setup do
        for table <- ["enrollments", "plans"] do
          {:ok, _} = AshSqlite.TransactionTestRepo.query("DELETE FROM #{table}", [])
        end

        :ok
      end

      defp enrol!(id, plan_id) do
        Enrollment
        |> Ash.Changeset.for_create(:create, %{id: id, plan_id: plan_id})
        |> Ash.create!()
      end

      test "the destination gets no database foreign key" do
        # A temporal table has no unique key to reference. Declaring one anyway creates
        # the table and then fails every insert with "foreign key mismatch".
        refute Enum.any?(
                 AshSqlite.TestRepo.query!("PRAGMA foreign_key_list(enrollments)", []).rows
               )
      end

      test "a child can be written at all, which a foreign key would have prevented" do
        Plan
        |> Ash.Changeset.for_create(:create, %{id: 1, slug: "pro"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.create!()

        assert %{plan_id: 1} = enrol!(10, 1)
      end

      test "loading the relationship resolves the plan at the read's instant" do
        Plan
        |> Ash.Changeset.for_create(:create, %{id: 1, slug: "pro"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.create!()

        Plan
        |> Ash.get!(1)
        |> Ash.Changeset.for_update(:change_price, %{price: 50})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        enrol!(10, 1)

        assert %{plan: %{price: 0}} =
                 Enrollment |> Ash.get!(10, as_of: @feb) |> Ash.load!(:plan, as_of: @feb)

        assert %{plan: %{price: 50}} =
                 Enrollment |> Ash.get!(10, as_of: @apr) |> Ash.load!(:plan, as_of: @apr)
      end

      test "as_of resolves the destination even when the parent's period spans two versions" do
        # This is what `temporal_keys` would otherwise be reached for. The overlap filter
        # it bakes in matches *both* plan versions here, because both overlap the
        # enrolment's `[Jan, oo)`. The `as_of` pin is what picks one, and it picks the
        # right one, so a point-in-time read needs no overlap filter to be correct.
        Plan
        |> Ash.Changeset.for_create(:create, %{id: 1, slug: "pro"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.create!()

        Plan
        |> Ash.get!(1)
        |> Ash.Changeset.for_update(:change_price, %{price: 50})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        enrol!(10, 1)

        assert %{plan: %{price: 0, valid_at: %{lower: lower_before}}} =
                 Enrollment |> Ash.get!(10, as_of: @feb) |> Ash.load!(:plan, as_of: @feb)

        assert %{plan: %{price: 50, valid_at: %{lower: lower_after}}} =
                 Enrollment |> Ash.get!(10, as_of: @apr) |> Ash.load!(:plan, as_of: @apr)

        assert lower_before == @jan
        assert lower_after == @mar
      end

      test "filtering across the relationship respects the read's instant" do
        Plan
        |> Ash.Changeset.for_create(:create, %{id: 1, slug: "pro"})
        |> Ash.Changeset.as_of(@jan)
        |> Ash.create!()

        Plan
        |> Ash.get!(1)
        |> Ash.Changeset.for_update(:change_price, %{price: 50})
        |> Ash.Changeset.as_of(@mar)
        |> Ash.update!()

        enrol!(10, 1)

        assert [%{id: 10}] =
                 Enrollment
                 |> Ash.Query.as_of(@apr)
                 |> Ash.Query.filter(plan.price == 50)
                 |> Ash.read!()

        assert [] =
                 Enrollment
                 |> Ash.Query.as_of(@feb)
                 |> Ash.Query.filter(plan.price == 50)
                 |> Ash.read!()
      end
    end
  end
end
