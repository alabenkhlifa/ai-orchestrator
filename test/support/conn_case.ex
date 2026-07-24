defmodule SddOrchestratorWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SddOrchestratorWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SddOrchestratorWeb.Endpoint

      use SddOrchestratorWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SddOrchestratorWeb.ConnCase
    end
  end

  setup tags do
    SddOrchestrator.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates an account, issues a session, and stores its opaque token in the test
  connection's session so protected routes resolve the account.
  """
  def register_and_log_in_account(%{conn: conn} = context) do
    account =
      SddOrchestrator.AccountsFixtures.account_fixture(
        Map.take(context, [:login, :github_user_id])
      )

    %{conn: log_in_account(conn, account), account: account}
  end

  @doc "Logs the given account into the connection via a real application session."
  def log_in_account(conn, account) do
    {:ok, token} = SddOrchestrator.Accounts.create_session(account)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:session_token, token)
  end
end
