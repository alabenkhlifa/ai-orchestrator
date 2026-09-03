defmodule SddOrchestrator.ProjectsFixtures do
  @moduledoc "Test fixtures for personal workspaces, projects, and onboarding attempts."

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.Pairing
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
  A worker paired to a device workspace that has never reported in, so discovery
  never detects it. Named for the state the product shows: paired, with nothing
  attached.
  """
  def unattached_worker_fixture(%DeviceWorkspace{id: device_workspace_id}) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    worker
  end

  @doc "A paired worker that reported in just now, so discovery detects it."
  def attached_worker_fixture(%DeviceWorkspace{} = device_workspace) do
    {:ok, worker} = device_workspace |> unattached_worker_fixture() |> Pairing.mark_seen()
    worker
  end

  @doc """
  Starts a device-origin attempt ready for hosted registration: a local repository
  is selected, hosted storage is chosen, and the given hosted workspace is proven
  by sign-in. Pass `nil` as the hosted workspace to leave the prerequisite unproven.

  Hosted registration binds the project to the worker that proved the repository,
  so the selection names an available one by default. Pass `worker_id:` to name a
  specific worker, or `worker_id: nil` to leave the selection without one.
  """
  def device_attempt_ready_for_hosted(device_workspace, hosted_workspace, opts \\ []) do
    repository =
      opts
      |> Keyword.get(:repository, local_repository_metadata())
      |> with_proving_worker(device_workspace, opts)

    attempt =
      device_workspace
      |> device_attempt_with_repository(repository)
      |> prove_hosted_prerequisite(device_workspace, hosted_workspace)

    {:ok, attempt} = Projects.select_storage_mode(device_workspace, attempt.id, "hosted")
    attempt
  end

  defp with_proving_worker(repository, device_workspace, opts) do
    case Keyword.fetch(opts, :worker_id) do
      {:ok, nil} -> repository
      {:ok, worker_id} -> Map.put(repository, :worker_id, worker_id)
      :error -> Map.put(repository, :worker_id, attached_worker_fixture(device_workspace).id)
    end
  end

  defp prove_hosted_prerequisite(attempt, _device_workspace, nil), do: attempt

  defp prove_hosted_prerequisite(attempt, device_workspace, hosted_workspace) do
    {:ok, attempt} =
      Projects.record_hosted_prerequisite(device_workspace, attempt.id, hosted_workspace)

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
