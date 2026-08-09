defmodule SddOrchestrator.ManagedRuntimeProfile do
  @moduledoc """
  One deterministic, allowlisted managed-runtime value for a project.

  Built on demand from the exact owner-approved repository execution profile
  (Slice 14), the selected pilot specification reference (Task 4), and the
  project's independent readiness (Task 12). Nothing here is persisted: a stale
  profile or pilot revision is refused at build time rather than served from a
  stored copy, and no specification document or repository file is ever read
  or written.

  Runtime-skill references are versioned by the content digest of this
  project's own canonical `.agents/skills/*/SKILL.md` files, computed at
  compile time so the value never depends on those files existing at runtime.
  """

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryPilots
  alias SddOrchestrator.RepositoryReadiness
  alias SddOrchestrator.SpecificationStore

  @type authority :: RepositoryPilots.authority()

  @type error ::
          :no_approved_profile
          | :no_pilot_selected
          | :stale_profile
          | :stale_pilot_revision
          | :unsupported_authority

  @fields [
    :profile_version,
    :repository_provider,
    :repository_id,
    :root,
    :base_revision,
    :assessment_digest,
    :commands,
    :required_checks,
    :allowed_scope,
    :pilot_specification_id,
    :pilot_revision_id,
    :pilot_revision_digest,
    :readiness,
    :runtime_skill_refs,
    :digest
  ]

  @value_keys MapSet.new(Enum.map(@fields, &Atom.to_string/1))
  @readiness_keys MapSet.new(
                    ~w(assistant specification agent_execution release earliest_blocked_stage)
                  )
  @runtime_skill_keys MapSet.new(~w(name version))

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          profile_version: pos_integer(),
          repository_provider: String.t(),
          repository_id: String.t(),
          root: String.t(),
          base_revision: String.t(),
          assessment_digest: String.t(),
          commands: [String.t()],
          required_checks: [String.t()],
          allowed_scope: [String.t()],
          pilot_specification_id: String.t(),
          pilot_revision_id: String.t(),
          pilot_revision_digest: String.t(),
          readiness: map(),
          runtime_skill_refs: [map()],
          digest: String.t()
        }

  @skill_names ~w(add-spec update-spec implement-spec review-spec)

  for skill_name <- @skill_names do
    @external_resource Path.expand("../../.agents/skills/#{skill_name}/SKILL.md", __DIR__)
  end

  @runtime_skill_refs Enum.map(@skill_names, fn skill_name ->
                        content =
                          "../../.agents/skills/#{skill_name}/SKILL.md"
                          |> Path.expand(__DIR__)
                          |> File.read!()

                        version =
                          :sha256
                          |> :crypto.hash(content)
                          |> Base.encode16(case: :lower)

                        %{"name" => skill_name, "version" => version}
                      end)

  @doc """
  Builds the exact allowlisted managed-runtime value for one project.

  Only a hosted owner or the owning device authority may build this value; it
  is not a participant read surface. Refuses when no profile is approved, no
  pilot is selected, the approved profile is no longer the pilot's profile
  version, or the pilot's specification revision is no longer current.
  """
  @spec build(authority(), String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def build(authority, project_id, opts \\ [])

  def build({:hosted, _account_id} = authority, project_id, opts),
    do: do_build(authority, project_id, opts)

  def build({:device, %DeviceWorkspace{}} = authority, project_id, opts),
    do: do_build(authority, project_id, opts)

  def build(_authority, _project_id, _opts), do: {:error, :unsupported_authority}

  defp do_build(authority, project_id, opts) do
    with {:ok, profile} <- current_profile(authority, project_id, opts),
         {:ok, pilot} <- current_pilot(authority, project_id, opts),
         :ok <- fresh_profile?(profile, pilot),
         {:ok, current_revision} <- current_specification_revision(authority, project_id, pilot),
         :ok <- fresh_revision?(current_revision, pilot) do
      readiness = RepositoryReadiness.evaluate(authority, project_id, opts)
      value = value(profile, pilot, readiness)
      {:ok, to_struct(value, digest(value))}
    end
  end

  @doc "Serializes the exact value without struct metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = value) do
    value
    |> Map.from_struct()
    |> Map.new(fn {key, field_value} -> {Atom.to_string(key), field_value} end)
  end

  @doc """
  Restores only an exact, digest-consistent value, rejecting any unknown or
  missing field at any nesting level and any tampered digest.
  """
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_managed_runtime_profile}
  def from_value(value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @value_keys,
         true <- valid_readiness_shape?(value["readiness"]),
         true <- valid_runtime_skill_refs_shape?(value["runtime_skill_refs"]),
         true <- digest(Map.delete(value, "digest")) == value["digest"] do
      {:ok, to_struct(value, value["digest"])}
    else
      _invalid -> {:error, :invalid_managed_runtime_profile}
    end
  rescue
    _error -> {:error, :invalid_managed_runtime_profile}
  end

  def from_value(_value), do: {:error, :invalid_managed_runtime_profile}

  @doc false
  @spec strict?(t()) :: boolean()
  def strict?(%__MODULE__{} = value) do
    encoded = to_value(value)

    case from_value(encoded) do
      {:ok, restored} -> to_value(restored) == encoded
      {:error, :invalid_managed_runtime_profile} -> false
    end
  rescue
    _error -> false
  end

  def strict?(_value), do: false

  ## Assembly

  defp value(profile, pilot, readiness) do
    %{
      "profile_version" => profile.version,
      "repository_provider" => profile.repository_provider,
      "repository_id" => profile.repository_id,
      "root" => profile.root,
      "base_revision" => profile.base_revision,
      "assessment_digest" => profile.assessment_digest,
      "commands" => profile.commands,
      "required_checks" => profile.required_checks,
      "allowed_scope" => profile.allowed_scope,
      "pilot_specification_id" => pilot.specification_id,
      "pilot_revision_id" => pilot.revision_id,
      "pilot_revision_digest" => pilot.revision_digest,
      "readiness" => readiness_value(readiness),
      "runtime_skill_refs" => @runtime_skill_refs
    }
  end

  defp readiness_value(%RepositoryReadiness{} = readiness) do
    %{
      "assistant" => axis_value(readiness.assistant),
      "specification" => axis_value(readiness.specification),
      "agent_execution" => axis_value(readiness.agent_execution),
      "release" => axis_value(readiness.release),
      "earliest_blocked_stage" => stage_value(readiness.earliest_blocked_stage)
    }
  end

  defp axis_value(:ready), do: "ready"
  defp axis_value({:blocked, reason}), do: "blocked:" <> Atom.to_string(reason)

  defp stage_value(nil), do: nil
  defp stage_value(stage) when is_atom(stage), do: Atom.to_string(stage)

  defp to_struct(value, digest) do
    value
    |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
    |> Map.put(:digest, digest)
    |> then(&struct!(__MODULE__, &1))
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  ## Shape validation

  defp valid_readiness_shape?(%{} = readiness),
    do: MapSet.new(Map.keys(readiness)) == @readiness_keys

  defp valid_readiness_shape?(_readiness), do: false

  defp valid_runtime_skill_refs_shape?(refs) when is_list(refs) do
    Enum.all?(refs, fn
      %{} = ref -> MapSet.new(Map.keys(ref)) == @runtime_skill_keys
      _other -> false
    end)
  end

  defp valid_runtime_skill_refs_shape?(_refs), do: false

  ## Staleness

  defp fresh_profile?(%{id: profile_id, version: profile_version}, %{
         profile_id: profile_id,
         profile_version: profile_version
       }),
       do: :ok

  defp fresh_profile?(_profile, _pilot), do: {:error, :stale_profile}

  defp fresh_revision?(%{revision: %{id: revision_id}}, %{revision_id: revision_id}), do: :ok
  defp fresh_revision?(_current, _pilot), do: {:error, :stale_pilot_revision}

  ## Reads
  #
  # `current_profile/3` and `current_pilot/3` duplicate `RepositoryPilots`' and
  # `RepositoryReadiness`' own private read conventions rather than exporting
  # them, consistent with those modules' precedent of not reaching into Slice
  # 14 or into each other.

  defp current_profile(authority, project_id, opts) do
    review_opts = Keyword.take(opts, [:profile_store, :assessment_store])

    case RepositoryAssessments.profile_review(authority, project_id, review_opts) do
      {:ok, %{profiles: []}} -> {:error, :no_approved_profile}
      {:ok, %{profiles: profiles}} -> {:ok, List.last(profiles)}
      {:error, _unavailable} -> {:error, :no_approved_profile}
    end
  end

  defp current_pilot(authority, project_id, opts) do
    pilot_opts = Keyword.take(opts, [:pilot_store])

    case RepositoryPilots.current(authority, project_id, pilot_opts) do
      {:ok, pilot} -> {:ok, pilot}
      {:error, :not_found} -> {:error, :no_pilot_selected}
    end
  end

  defp current_specification_revision(authority, project_id, pilot) do
    with {:ok, store_authority} <- store_authority(authority),
         {:ok, current} <-
           SpecificationStore.get_current(store_authority, project_id, pilot.specification_id) do
      {:ok, current}
    else
      _unavailable -> {:error, :stale_pilot_revision}
    end
  end

  defp store_authority({:hosted, account_id}) do
    case Accounts.get_personal_workspace(account_id) do
      %PersonalWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :stale_pilot_revision}
    end
  end

  defp store_authority({:device, %DeviceWorkspace{} = workspace}), do: {:ok, workspace}
end
