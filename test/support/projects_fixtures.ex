defmodule SddOrchestrator.ProjectsFixtures do
  @moduledoc "Test fixtures for personal workspaces, projects, and onboarding attempts."

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt
  alias SddOrchestrator.Repo

  @doc "Restores (or creates) the personal workspace for an account."
  def workspace_fixture(%Account{} = account) do
    Accounts.get_or_create_personal_workspace(account)
  end

  @doc "Creates a project in the given workspace."
  def project_fixture(workspace, attrs \\ %{}) do
    name = attrs[:name] || "project-#{System.unique_integer([:positive])}"

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{name: name, workspace_id: workspace.id})
      |> Repo.insert()

    project
  end

  @doc "A representative selected-repository metadata map."
  def repository_metadata(attrs \\ %{}) do
    Map.merge(
      %{
        id: 101,
        owner: "octo",
        name: "example",
        full_name: "octo/example",
        private: false,
        visibility: "public",
        html_url: "https://github.com/octo/example",
        organization: nil
      },
      Map.new(attrs)
    )
  end

  @doc "Starts an onboarding attempt with a repository already selected."
  def attempt_with_repository(workspace, repository \\ repository_metadata()) do
    {:ok, attempt} = Projects.start_onboarding_attempt(workspace)
    {:ok, attempt} = Projects.select_repository(workspace, attempt.id, repository)
    attempt
  end

  @doc """
  Starts an onboarding attempt ready for confirmation: a repository is selected and
  a storage mode chosen (hosted by default), so `register_project/3` can run.
  """
  def attempt_ready(workspace, opts \\ []) do
    repository = Keyword.get(opts, :repository, repository_metadata())
    mode = Keyword.get(opts, :storage_mode, "hosted")

    attempt = attempt_with_repository(workspace, repository)
    {:ok, attempt} = Projects.select_storage_mode(workspace, attempt.id, mode)
    attempt
  end

  @doc "A device workspace value (accountless local origin), distinct per call."
  def device_workspace_fixture do
    %DeviceWorkspace{id: Ecto.UUID.generate()}
  end

  @doc "The approved minimum local-repository metadata (fingerprint + display name)."
  def local_repository_metadata(attrs \\ %{}) do
    unique = Integer.to_string(System.unique_integer([:positive]))
    salt = :crypto.hash(:sha256, "fixture-salt:" <> unique)
    digest = :crypto.hash(:sha256, "fixture-digest:" <> unique)

    fingerprint =
      "local-repo:v1:#{Base.url_encode64(salt, padding: false)}:" <>
        Base.url_encode64(digest, padding: false)

    Map.merge(
      %{fingerprint: fingerprint, name: "local-example"},
      Map.new(attrs)
    )
  end

  @doc "Starts a device-origin (accountless) attempt with a local repository selected."
  def device_attempt_with_repository(device_workspace, repository \\ local_repository_metadata()) do
    {:ok, attempt} = Projects.start_device_onboarding_attempt(device_workspace)
    {:ok, attempt} = Projects.select_local_repository(device_workspace, attempt.id, repository)
    attempt
  end

  @doc """
  Builds a bound, minimized device-readiness receipt for an attempt. Binds to the
  attempt id and, for a device-origin attempt, the attempt's device workspace by
  default; override any field through `attrs`.
  """
  def device_receipt(attempt, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    DeviceStorageReceipt.issue(%{
      token: attrs[:token] || "opaque-#{System.unique_integer([:positive])}",
      attempt_id: attrs[:attempt_id] || attempt.id,
      device_workspace_id:
        attrs[:device_workspace_id] || attempt.device_workspace_id || Ecto.UUID.generate(),
      nonce: attrs[:nonce] || Ecto.UUID.generate(),
      issued_at: attrs[:issued_at] || now,
      expires_at: attrs[:expires_at] || DateTime.add(now, 3600, :second)
    })
  end

  @doc "Registers a project in a workspace through the real registration transaction."
  def registered_project(workspace, opts \\ []) do
    attempt = attempt_ready(workspace, opts)
    {:ok, project} = Projects.register_project(workspace, attempt, Keyword.take(opts, [:name]))
    project
  end
end
