defmodule SddOrchestrator.ProjectAssistant.RepositoryExclusionsTest do
  @moduledoc """
  specs/12-project-assistant Task 5 focused proof: configured path and file
  exclusions (AC-19's exclusion half) deny generated and sensitive paths by
  default, independent of any redaction Task 9 later owns.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.RepositoryExclusions

  describe "default configured exclusions" do
    test "denies generated and vendored directories" do
      assert RepositoryExclusions.denied?("node_modules/left-pad/index.js")
      assert RepositoryExclusions.denied?("_build/dev/lib/app/ebin/app.beam")
      assert RepositoryExclusions.denied?("deps/phoenix/mix.exs")
      assert RepositoryExclusions.denied?("dist/bundle.js")
    end

    test "denies conventional secret-bearing paths" do
      assert RepositoryExclusions.denied?(".env")
      assert RepositoryExclusions.denied?(".env.production")
      assert RepositoryExclusions.denied?("config/secrets/credentials.yml")
      assert RepositoryExclusions.denied?("id_rsa")
      assert RepositoryExclusions.denied?(".ssh/id_ed25519")
      assert RepositoryExclusions.denied?("server.pem")
      assert RepositoryExclusions.denied?("keys/private.key")
    end

    test "does not deny ordinary source paths" do
      refute RepositoryExclusions.denied?("lib/sdd_orchestrator/application.ex")
      refute RepositoryExclusions.denied?("README.md")
      refute RepositoryExclusions.denied?("test/sdd_orchestrator/application_test.exs")
    end
  end

  describe "reject_denied/2" do
    test "filters a mixed path list down to only allowed paths" do
      paths = ["lib/app.ex", "node_modules/x/index.js", ".env", "README.md"]

      assert RepositoryExclusions.reject_denied(paths) == ["lib/app.ex", "README.md"]
    end
  end

  describe "configured/0" do
    test "falls back to the built-in default list" do
      assert "node_modules/" in RepositoryExclusions.configured()
      assert ".env" in RepositoryExclusions.configured()
    end

    test "respects an application-configured override" do
      Application.put_env(:sdd_orchestrator, :repository_discovery_exclusions, ["only_this/"])

      on_exit(fn ->
        Application.delete_env(:sdd_orchestrator, :repository_discovery_exclusions)
      end)

      assert RepositoryExclusions.configured() == ["only_this/"]
      assert RepositoryExclusions.denied?("only_this/file.ex")
      refute RepositoryExclusions.denied?("node_modules/x.js")
    end
  end
end
