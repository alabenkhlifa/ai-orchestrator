defmodule SddOrchestrator.Delivery.ProcessingDisclosure do
  @moduledoc """
  What a participant is told before development starts, and what they agreed to.

  Starting development can send a project's specifications, source context,
  prompts, outputs, and evidence across a device, hosting, worker, model, or
  preview boundary. An explicit start is only an informed one if the person
  pressing the button can see where the work will run, which agent and model
  provider it will use, whether a preview provider is configured, and whether
  content leaves its authoritative store.

  The agreement is recorded as the digest of exactly what was shown. That is
  what makes a later configuration change invalidate it: the person did not
  agree to a boundary that did not exist yet. An unchanged boundary reuses the
  earlier confirmation, so a routine run is not interrupted to re-read the same
  disclosure.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Delivery.{CanonicalJson, ParticipantGuard}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @disclosure_version 1

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @type disclosure :: %{
          version: pos_integer(),
          digest: String.t(),
          execution_location: String.t(),
          agent_provider: String.t(),
          model_provider: String.t(),
          preview_provider: String.t() | nil,
          leaves_authoritative_store: boolean(),
          transfers: [String.t()]
        }

  schema "processing_confirmations" do
    field :disclosure_version, :integer
    field :disclosure_digest, :string
    field :confirmed_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :account, Account

    timestamps()
  end

  @spec disclosure_version() :: pos_integer()
  def disclosure_version, do: @disclosure_version

  @doc """
  Builds the disclosure for one project from the current configuration.

  The digest covers every disclosed field, so changing any of them — the
  execution location, either provider, the preview path, or whether content
  leaves its store — produces a different agreement.
  """
  @spec describe(keyword()) :: disclosure()
  def describe(config \\ configured()) do
    execution_location = Keyword.get(config, :execution_location, "local worker")
    agent_provider = Keyword.get(config, :agent_provider, "unconfigured")
    model_provider = Keyword.get(config, :model_provider, "unconfigured")
    preview_provider = Keyword.get(config, :preview_provider)
    transfers = config |> Keyword.get(:transfers, []) |> Enum.sort()

    fields = %{
      "execution_location" => execution_location,
      "agent_provider" => agent_provider,
      "model_provider" => model_provider,
      "preview_provider" => preview_provider || "none",
      "transfers" => transfers,
      "version" => @disclosure_version
    }

    %{
      version: @disclosure_version,
      digest: digest(fields),
      execution_location: execution_location,
      agent_provider: agent_provider,
      model_provider: model_provider,
      preview_provider: preview_provider,
      leaves_authoritative_store: transfers != [],
      transfers: transfers
    }
  end

  @doc """
  Reports whether this person has confirmed the boundary currently in force.

  False before the first start and again after the disclosed boundary changes,
  which are exactly the two moments a confirmation is required.
  """
  @spec confirmed?(Ecto.UUID.t(), ParticipantGuard.actor(), disclosure()) :: boolean()
  def confirmed?(project_id, actor, disclosure \\ describe()) do
    case current(project_id, actor) do
      {:ok, confirmation} -> confirmation.disclosure_digest == disclosure.digest
      :error -> false
    end
  end

  @doc """
  Records this person's confirmation of exactly what they were shown.

  The caller passes the digest it displayed; a digest that no longer matches
  the current configuration is refused, so a confirmation cannot be replayed
  against a boundary that changed while the dialog was open.
  """
  @spec confirm(Ecto.UUID.t(), ParticipantGuard.actor(), String.t(), disclosure()) ::
          {:ok, t()} | {:error, :unauthorized | :boundary_changed | Ecto.Changeset.t()}
  def confirm(project_id, actor, digest, disclosure \\ describe()) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :start_run),
         :ok <- matches?(digest, disclosure) do
      record(project_id, member.account_id, disclosure)
    end
  end

  @doc "The current confirmation for one person on one project, when it exists."
  @spec current(Ecto.UUID.t(), ParticipantGuard.actor()) :: {:ok, t()} | :error
  def current(project_id, actor) do
    case ParticipantGuard.authorize_action(project_id, actor, :view_feature) do
      {:ok, member} -> confirmation_for(project_id, member.account_id)
      {:error, :unauthorized} -> :error
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @doc "The configured processing boundary for this deployment."
  @spec configured() :: keyword()
  def configured, do: Application.get_env(:sdd_orchestrator, :processing_boundary, [])

  defp confirmation_for(project_id, account_id) do
    case Repo.get_by(__MODULE__, project_id: project_id, account_id: account_id) do
      nil -> :error
      confirmation -> {:ok, confirmation}
    end
  end

  defp record(project_id, account_id, disclosure) do
    existing =
      Repo.get_by(__MODULE__, project_id: project_id, account_id: account_id) || %__MODULE__{}

    existing
    |> change(%{
      project_id: project_id,
      account_id: account_id,
      disclosure_version: disclosure.version,
      disclosure_digest: disclosure.digest,
      confirmed_at: DateTime.utc_now()
    })
    |> validate_required([
      :project_id,
      :account_id,
      :disclosure_version,
      :disclosure_digest,
      :confirmed_at
    ])
    |> unique_constraint([:project_id, :account_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:account_id)
    |> Repo.insert_or_update()
  end

  defp matches?(digest, %{digest: digest}), do: :ok
  defp matches?(_digest, _disclosure), do: {:error, :boundary_changed}

  # Every disclosed field is a plain scalar or a sorted list of them, so a
  # canonical encoding cannot fail here; a match error would be a real defect
  # rather than a condition to handle.
  defp digest(fields) do
    {:ok, canonical} = CanonicalJson.encode(fields)

    :sha256 |> :crypto.hash(canonical) |> Base.encode16(case: :lower)
  end
end
