# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Verifiers.VerifyTemporal do
  @moduledoc """
  Refuses a temporal resource whose repo does not run write transactions.

  Postgres splits a period with one statement, so it is atomic whether or not the
  caller opened a transaction. SQLite has no `FOR PORTION OF`, so the same split is a
  close, an insert and an update (`AshSqlite.Temporal`). Run without a transaction,
  a failure between them leaves the record with two current versions or none, and the
  partial unique index catches only the first of those.

  `AshPostgres.Verifiers.VerifyTemporal` checks for `btree_gist` for the same reason:
  the data layer cannot deliver the guarantee without something the application has to
  turn on, so it says so at compile time rather than at the first failed write.
  """
  use Spark.Dsl.Verifier

  # Against a released ash there is no `temporal` section, so there is nothing here to
  # check and every branch below is dead code.
  if AshSqlite.Temporal.supported?() do
    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError

    @impl true
    def verify(dsl_state) do
      resource = Verifier.get_persisted(dsl_state, :module)

      if temporal?(dsl_state) and not write_transactions?(dsl_state, resource) do
        {:error,
         DslError.exception(
           module: resource,
           path: [:temporal, :strategy],
           message: """
           A temporal resource requires a repo with write transactions enabled.

           A period split on SQLite is three statements, and only a transaction makes
           them one write. Define `write_transactions?/0` as `true` on the repo:

               defmodule #{inspect(repo(dsl_state))} do
                 use AshSqlite.Repo, otp_app: :my_app

                 def write_transactions?, do: true
               end
           """
         )}
      else
        :ok
      end
    end

    defp temporal?(dsl_state) do
      not is_nil(Verifier.get_option(dsl_state, [:temporal], :strategy))
    end

    # The `repo` option is either a module or a 2-arity function of the resource and the
    # operation (see `test/support/resources/named_fn_repo_account.ex`). `Code.ensure_loaded?/1`
    # is guarded on an atom and raises on a capture, so the function has to be resolved
    # first. The resource module does not exist yet, so it is passed as nil, which is
    # what the option's own callers tolerate.
    defp repo(dsl_state) do
      case Verifier.get_option(dsl_state, [:sqlite], :repo) do
        repo when is_function(repo, 2) -> repo.(nil, :mutate)
        repo -> repo
      end
    end

    defp write_transactions?(dsl_state, _resource) do
      case repo(dsl_state) do
        repo when is_atom(repo) and not is_nil(repo) ->
          Code.ensure_loaded?(repo) and repo.write_transactions?()

        _other ->
          true
      end
    end
  else
    @impl true
    def verify(_dsl_state), do: :ok
  end
end
