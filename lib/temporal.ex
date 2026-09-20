# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Temporal do
  @moduledoc """
  The period arithmetic a temporal resource needs, performed in the data layer.

  Postgres splits a period with one statement: `UPDATE ... FOR PORTION OF valid_at
  FROM $as_of TO NULL`. SQLite has no such clause, and no data-modifying CTE to
  build one out of, so the same outcome takes three statements:

  1. close the version whose period contains `as_of`, at `as_of`,
  2. copy that row forward with the period `[as_of, prior_upper)`,
  3. apply the caller's update to the copy.

  Step 3 is the ordinary non-temporal update path, which is the whole reason the
  split is shaped this way: atomics, `RETURNING` and the changeset's filters all
  keep working without a temporal branch inside them.

  The order matters and is not an implementation detail. Closing before inserting
  means the two periods never overlap at any point between statements, so the
  non-overlap trigger the migration generator emits never sees a transient
  violation. The reverse order would trip it.

  All three run inside one transaction, which is why
  `AshSqlite.DataLayer.Info.write_transactions?/1` must be true for a temporal
  resource. Without it a split that fails halfway leaves a record with either two
  current versions or none.
  """

  alias AshSqlite.Type.RangeBound

  # Temporal is unreleased: it exists on ash's `temporal` branch and not in any hex
  # version. Everything below is compiled only when it is present, so ash_sqlite built
  # against a released ash behaves exactly as it did before -- `temporal?/1` answers
  # false, the data layer reports no temporal support, and no call reaches a function
  # that is not there.
  @supported? Code.ensure_loaded?(Ash.Temporal)

  @doc "Whether the ash this was compiled against has temporal resources."
  def supported?, do: @supported?

  # Only these three reach into ash's temporal API. Gating them here rather than the
  # whole module keeps every other function defined against a released ash, so nothing
  # that calls them warns about a function that is not there.
  if @supported? do
    @doc "The attribute holding the period, or nil for a non-temporal resource."
    def attribute(resource), do: Ash.Resource.Info.temporal_attribute(resource)

    @doc "Whether this resource stores its rows as periods."
    def temporal?(resource), do: Ash.Resource.Info.temporal?(resource)

    @doc """
    The instant a write takes effect.

    A changeset that names no `as_of` takes effect now. A resource whose period type
    has no current value has no such instant, and that is an error rather than a
    default -- a resource numbering its versions from one has no `:now` to give.
    """
    @doc """
    The fields that identify one row.

    On a temporal table the primary key names every version of a record, so the period
    completes the identity. Anything that aims a statement at a single row filters or
    joins on this rather than on the key alone.
    """
    def identity_fields(resource) do
      case attribute(resource) do
        nil -> Ash.Resource.Info.primary_key(resource)
        attribute -> Ash.Resource.Info.primary_key(resource) ++ [attribute]
      end
    end

    def write_instant(resource, %{as_of: as_of}), do: write_instant(resource, as_of)

    def write_instant(resource, as_of) do
      case Ash.Temporal.write_instant(resource, as_of || :now) do
        {:ok, instant} ->
          instant

        :error ->
          raise ArgumentError, "#{inspect(resource)} has no write instant for #{inspect(as_of)}"
      end
    end
  else
    @doc "The attribute holding the period, or nil for a non-temporal resource."
    def attribute(_resource), do: nil

    @doc "Whether this resource stores its rows as periods."
    def temporal?(_resource), do: false

    # Unreachable: `temporal?/1` is the only gate into anything that asks for a write
    # instant, and it is false in this build. It returns a value rather than raising so
    # that the orchestration below still type-checks here, where it is never called.
    @doc false
    def identity_fields(resource), do: Ash.Resource.Info.primary_key(resource)

    @doc false
    def write_instant(_resource, _as_of), do: nil
  end

  @doc "The period a write opens: `[as_of, upper)`, unbounded above unless a later version bounds it."
  def period(resource, as_of, upper \\ nil) do
    %Ash.Range{
      lower: as_of,
      upper: upper,
      bounds: bounds(resource),
      empty?: false
    }
  end

  defp bounds(resource) do
    case attribute(resource) && Ash.Resource.Info.attribute(resource, attribute(resource)) do
      %{constraints: constraints} ->
        lower = get_in(constraints, [:lower, :inclusive?])
        upper = get_in(constraints, [:upper, :inclusive?])

        case {lower == false, upper == true} do
          {false, false} -> :"[)"
          {false, true} -> :"[]"
          {true, false} -> :"()"
          {true, true} -> :"(]"
        end

      _other ->
        :"[)"
    end
  end

  @doc """
  The SQL expression for a period bound.

  The bounds stay inside the JSON rather than being projected into generated
  columns, because SQLite indexes an expression directly and the planner matches
  an index on `json_extract(valid_at, '$.lower')` to this same expression, alias
  and quoting included. Measured: `SEARCH ... USING INDEX ... (id=? AND <expr><?)`.
  Generated columns reach the same plan and cost two columns and an exclusion list
  everywhere a row is copied.
  """
  def lower_expr(attribute, prefix \\ nil),
    do: "json_extract(#{qualify(attribute, prefix)}, '$.lower')"

  def upper_expr(attribute, prefix \\ nil),
    do: "json_extract(#{qualify(attribute, prefix)}, '$.upper')"

  defp qualify(attribute, nil), do: quote_name(attribute)
  defp qualify(attribute, prefix), do: "#{prefix}.#{quote_name(attribute)}"

  @doc """
  Runs `fun` with the three statements of a split inside one transaction.

  Ash does not open one for us. `Ash.Actions.Update.Bulk` wraps an atomic update only
  when the resource has after-batch hooks or asks for
  `prefer_transaction_for_atomic_updates?`, and this data layer answers that `false`
  because a non-temporal atomic update is a single statement and does not need one.
  A split is three, so without this a failure in the third leaves the record with its
  history already rewritten and no current version restored, and two concurrent writers
  interleave their statements and lose one of the two writes.

  `mode: :immediate` for the reason `transaction/4` gives: a deferred transaction that
  reads and then writes has to upgrade its lock, and SQLite fails an upgrade outright
  rather than waiting for `busy_timeout`.
  """
  def transactionally(repo, fun) do
    if repo.in_transaction?() do
      fun.()
    else
      result =
        repo.transaction(
          fn ->
            case fun.() do
              {:error, reason} -> repo.rollback(reason)
              other -> other
            end
          end,
          mode: :immediate
        )

      case result do
        {:ok, value} -> value
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Encodes an instant the way period bounds are encoded, so the two compare."
  def encode(instant), do: RangeBound.encode(instant)

  # `Ash.Type.Range` allows `:date`, `:integer`, `:naive_datetime` and `:datetime`
  # bounds, and `DateTime.compare/2` raises a FunctionClauseError on the first three.
  # Comparing the encoded forms works for all four, and it is the same comparison the
  # database performs on the stored bounds, so the two can never disagree.
  defp same_bound?(left, right), do: encode(left) == encode(right)

  @doc """
  The SQL that selects the version valid at an instant, and its parameters.

  The lower bound is compared inclusively and the upper exclusively, matching the
  default `[)` bounds. An unbounded upper is `NULL`, so "still current" is
  `IS NULL` rather than a comparison against a sentinel.
  """
  def valid_at_sql(attribute) do
    lo = lower_expr(attribute)
    hi = upper_expr(attribute)
    "(#{lo} <= ? AND (#{hi} IS NULL OR #{hi} > ?))"
  end

  @doc """
  Reads the version of `pkey` valid at `as_of`, as `{rowid, %Ash.Range{}}`.

  Returns `nil` when the record has no version covering that instant, which is
  what an update against a gap, or against a time before the record existed, has
  to distinguish from a version it can split.
  """
  def current_version(repo, resource, pkey, as_of) do
    attribute = attribute(resource)
    table = AshSqlite.DataLayer.Info.table(resource)
    {where, params} = pkey_where(pkey)
    encoded = encode(as_of)

    sql =
      "SELECT rowid, #{quote_name(attribute)} FROM #{quote_name(table)} " <>
        "WHERE #{where} AND #{valid_at_sql(attribute)} LIMIT 1"

    case repo.query!(sql, params ++ [encoded, encoded]) do
      %{rows: [[rowid, stored]]} -> {rowid, decode_range(resource, attribute, stored)}
      %{rows: []} -> nil
    end
  end

  @doc """
  The lower bound of the earliest version of `pkey` that begins at or after `as_of`.

  A write into a gap is bounded above by the version that follows it, so that the
  new period does not run through one that already exists. With no later version
  the period is unbounded.
  """
  def next_lower_bound(repo, resource, pkey, as_of) do
    attribute = attribute(resource)
    table = AshSqlite.DataLayer.Info.table(resource)
    {where, params} = pkey_where(pkey)
    lo = lower_expr(attribute)

    sql =
      "SELECT #{lo} FROM #{quote_name(table)} " <>
        "WHERE #{where} AND #{lo} >= ? ORDER BY #{lo} LIMIT 1"

    case repo.query!(sql, params ++ [encode(as_of)]) do
      %{rows: [[bound]]} -> cast_bound(resource, attribute, bound)
      %{rows: []} -> nil
    end
  end

  @doc """
  Closes the version at `rowid` at `as_of`, and returns the period it had.

  A version whose period begins exactly at `as_of` is not closed — there is no
  before-portion to keep, and closing it would leave an empty period. The caller
  distinguishes the two by the `:replace` return.
  """
  def close_version(repo, resource, rowid, %Ash.Range{} = prior, as_of) do
    if same_bound?(prior.lower, as_of) do
      :replace
    else
      attribute = attribute(resource)
      table = AshSqlite.DataLayer.Info.table(resource)
      closed = %{prior | upper: as_of}

      repo.query!(
        "UPDATE #{quote_name(table)} SET #{quote_name(attribute)} = ? WHERE rowid = ?",
        [dump!(closed), rowid]
      )

      {:closed, prior}
    end
  end

  @doc """
  Copies the row at `rowid` forward under a new period, and returns the new rowid.

  Every column is copied except the period and the generated bound columns, so a
  column added to the table later is carried without this function knowing about
  it. The caller then applies its own changes to the copy.
  """
  def copy_forward(repo, resource, rowid, period) do
    attribute = attribute(resource)
    table = AshSqlite.DataLayer.Info.table(resource)
    columns = copyable_columns(repo, table, attribute)
    column_list = Enum.map_join(columns, ", ", &quote_name/1)

    %{rows: [[new_rowid]]} =
      repo.query!(
        "INSERT INTO #{quote_name(table)} (#{column_list}, #{quote_name(attribute)}) " <>
          "SELECT #{column_list}, ? FROM #{quote_name(table)} WHERE rowid = ? " <>
          "RETURNING rowid",
        [dump!(period), rowid]
      )

    new_rowid
  end

  # Every column of the table except the period, which the caller supplies. Reading
  # the columns from the table rather than from the resource means a column the
  # resource does not declare is still carried forward by a split, instead of being
  # silently dropped from the new version.
  defp copyable_columns(repo, table, attribute) do
    repo.query!("SELECT name FROM pragma_table_info(?)", [table])
    |> Map.fetch!(:rows)
    |> List.flatten()
    |> Enum.reject(&(&1 == to_string(attribute)))
  end

  defp pkey_where(pkey) do
    {clauses, params} =
      pkey
      |> Enum.map(fn {key, value} -> {"#{quote_name(key)} = ?", value} end)
      |> Enum.unzip()

    {Enum.join(clauses, " AND "), params}
  end

  defp dump!(%Ash.Range{} = range) do
    {:ok, dumped} = AshSqlite.Type.Range.dump(range, nil, %{})
    dumped
  end

  defp decode_range(resource, attribute, stored) do
    params = range_params(resource, attribute)
    {:ok, range} = AshSqlite.Type.Range.load(stored, nil, params)
    range
  end

  defp cast_bound(_resource, _attribute, nil), do: nil

  defp cast_bound(resource, attribute, stored) do
    %{inner_type: inner_type, inner_constraints: inner_constraints} =
      range_params(resource, attribute)

    case Ash.Type.cast_stored(inner_type, stored, inner_constraints) do
      {:ok, value} -> value
      _other -> stored
    end
  end

  defp range_params(resource, attribute) do
    constraints = Ash.Resource.Info.attribute(resource, attribute).constraints

    %{
      inner_type: Ash.Type.get_type(constraints[:inner_type]),
      inner_constraints: constraints[:inner_constraints] || []
    }
  end

  # SQLite quotes an identifier with double quotes, and escapes an embedded one by
  # doubling it. Table and column names reach here from the DSL rather than from a
  # request, but interpolating them unquoted would still break on a name that needs
  # quoting at all.
  defp quote_name(name) do
    escaped = name |> to_string() |> String.replace("\"", "\"\"")
    "\"" <> escaped <> "\""
  end

  @doc """
  Loads the row at `rowid` as a resource struct.

  An upsert that matched has to hand Ash back the record as it now stands, and the
  changeset only carries the keys and the fields the action nominated. Reading the row
  is what makes the untouched attributes real rather than the struct's defaults.
  """
  def version_at(repo, resource, rowid) do
    import Ecto.Query, only: [from: 2]

    repo.one(from(row in resource, where: fragment("rowid") == ^rowid))
  end

  @doc "The period stored at `rowid`."
  def period_of(repo, resource, rowid) do
    attribute = attribute(resource)
    table = AshSqlite.DataLayer.Info.table(resource)

    %{rows: [[stored]]} =
      repo.query!(
        "SELECT #{quote_name(attribute)} FROM #{quote_name(table)} WHERE rowid = ?",
        [rowid]
      )

    decode_range(resource, attribute, stored)
  end

  @doc """
  Splits the version at `rowid` at `as_of`, returning what the caller must do next.

  `:replace` means the version began at `as_of` and was left alone, so an update
  applies to it directly and a destroy deletes it. `{:split, new_rowid}` means the
  version was closed and copied forward.
  """
  def split_rowid(repo, resource, rowid, as_of) do
    prior = period_of(repo, resource, rowid)

    case close_version(repo, resource, rowid, prior, as_of) do
      :replace ->
        :replace

      {:closed, prior} ->
        {:split, copy_forward(repo, resource, rowid, period(resource, as_of, prior.upper))}
    end
  end

  @doc """
  Splits every version in `rowids` at `as_of`.

  This is the set-wide path, and it is one statement pair per row where Postgres
  issues a single `FOR PORTION OF`. The rows are known to be the ones the caller's
  query matched, so there is no second filter pass.

  After this returns, a query carrying the `as_of` containment filter matches exactly
  the new versions: each prior version now ends at `as_of`, which the filter excludes,
  and each new one begins there, which it includes. That is what lets the caller run
  its original statement unchanged rather than re-targeting it at the copies.
  """
  def split_all(repo, resource, rowids, as_of) do
    Enum.each(rowids, &split_rowid(repo, resource, &1, as_of))
  end

  @doc """
  Ends the validity of every version in `rowids` at `as_of`.

  Returns the rowids that must still be deleted: those whose period began exactly at
  `as_of` and so have no before-portion worth keeping.
  """
  def truncate_all(repo, resource, rowids, as_of) do
    Enum.filter(rowids, fn rowid ->
      prior = period_of(repo, resource, rowid)
      close_version(repo, resource, rowid, prior, as_of) == :replace
    end)
  end

  @doc """
  Performs a temporal update, and hands the caller a changeset aimed at the new version.

  The split happens here; the caller's function then runs the ordinary update against
  the copy. `continue` receives the changeset with its `data` re-pointed at the new
  version, which is what makes the row identity `(primary key, period)` resolve to
  exactly one row.

  A write that lands on a version's own lower bound has no before-portion to keep, so
  it updates that version in place rather than splitting it. Splitting there would
  leave an empty `[as_of, as_of)` period behind.
  """
  def update(repo, resource, changeset, continue) do
    as_of = write_instant(resource, changeset)
    pkey = pkey_of(resource, changeset.data)

    case current_version(repo, resource, pkey, as_of) do
      nil ->
        {:error,
         Ash.Error.Changes.StaleRecord.exception(
           resource: resource,
           filter: changeset.filter
         )}

      {rowid, prior} ->
        period =
          case close_version(repo, resource, rowid, prior, as_of) do
            :replace ->
              prior

            {:closed, prior} ->
              new_period = period(resource, as_of, prior.upper)
              copy_forward(repo, resource, rowid, new_period)
              new_period
          end

        continue.(aim_at(changeset, resource, period))
    end
  end

  @doc """
  Ends a record's validity at `as_of`, keeping everything before it.

  A destroy landing on the version's own lower bound deletes it, because truncating a
  period to zero width is not a period. Any other instant closes the version and
  leaves the history in place, which is why a temporal destroy is not a delete.
  """
  def destroy(repo, resource, changeset, delete) do
    as_of = write_instant(resource, changeset)
    pkey = pkey_of(resource, changeset.data)

    case current_version(repo, resource, pkey, as_of) do
      nil ->
        :ok

      {rowid, prior} ->
        case close_version(repo, resource, rowid, prior, as_of) do
          :replace -> delete.(aim_at(changeset, resource, prior))
          {:closed, _prior} -> :ok
        end
    end
  end

  # Re-points a changeset at one version of a record. The data layer filters an update
  # by the row identity it reads off `changeset.data`, and for a temporal resource that
  # identity is the primary key *plus* the period -- the key alone names every version.
  defp aim_at(changeset, resource, period) do
    %{changeset | data: Map.put(changeset.data, attribute(resource), period)}
  end

  defp pkey_of(resource, record) do
    resource
    |> Ash.Resource.Info.primary_key()
    |> Map.new(fn key -> {key, Map.fetch!(record, key)} end)
  end
end
