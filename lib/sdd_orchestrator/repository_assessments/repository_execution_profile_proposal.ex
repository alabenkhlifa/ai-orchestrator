defmodule SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfileProposal do
  @moduledoc """
  Strict transient proposal derived from one completed repository assessment.

  Repository binding and instruction precedence are always derived from the
  authoritative assessment. The caller may supply only normalized managed-run
  commands, required checks, allowed scope, and visible blocker codes. A
  proposal is not authoritative project data and cannot be approved after any
  assessment-owned field changes.
  """

  alias SddOrchestrator.RepositoryAssessments.{RepositoryAssessment, RepositoryBindingPreparation}

  @input_fields [
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers
  ]

  @fields [
    :assessment_id,
    :assessment_digest,
    :project_id,
    :repository_provider,
    :repository_id,
    :root,
    :base_revision,
    :instruction_precedence,
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers,
    :proposal_digest
  ]

  @enforce_keys @fields
  defstruct @fields

  @max_items 64
  @max_command_bytes 1_024
  @max_code_bytes 128

  @type t :: %__MODULE__{}

  @doc "Builds one proposal without accepting caller-owned binding or precedence fields."
  @spec new(RepositoryAssessment.t(), map()) :: {:ok, t()} | {:error, :invalid_proposal}
  def new(%RepositoryAssessment{state: "completed"} = assessment, attrs) when is_map(attrs) do
    with true <- RepositoryAssessment.strict?(assessment),
         true <- RepositoryAssessment.cache_provenance_complete?(assessment),
         {:ok, input} <- normalize_input(attrs),
         {:ok, commands} <- normalize_commands(input.commands),
         {:ok, required_checks} <- normalize_commands(input.required_checks),
         true <- MapSet.subset?(MapSet.new(required_checks), MapSet.new(commands)),
         {:ok, allowed_scope} <- normalize_scope(input.allowed_scope, assessment.root, false),
         {:ok, gaps} <- normalize_codes(input.gaps),
         {:ok, conflicts} <- normalize_codes(input.conflicts),
         {:ok, multi_root_blockers} <-
           normalize_scope(input.multi_root_blockers, assessment.root, true),
         true <-
           evidence_supports?(
             assessment,
             commands,
             required_checks,
             allowed_scope,
             multi_root_blockers
           ) do
      values = %{
        assessment_id: assessment.id,
        assessment_digest: assessment_digest(assessment),
        project_id: assessment.project_id,
        repository_provider: assessment.repository_provider,
        repository_id: assessment.repository_id,
        root: assessment.root,
        base_revision: assessment.commit,
        instruction_precedence: instruction_precedence(assessment),
        commands: commands,
        required_checks: required_checks,
        allowed_scope: allowed_scope,
        gaps: gaps,
        conflicts: conflicts,
        multi_root_blockers: multi_root_blockers
      }

      {:ok, struct!(__MODULE__, Map.put(values, :proposal_digest, digest(values)))}
    else
      _invalid -> {:error, :invalid_proposal}
    end
  rescue
    _error -> {:error, :invalid_proposal}
  end

  def new(_assessment, _attrs), do: {:error, :invalid_proposal}

  @doc "Restores only the exact allowlisted proposal value used by the device store."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_proposal}
  def from_value(value) when is_map(value) do
    expected = MapSet.new(Enum.map(@fields, &Atom.to_string/1))

    case MapSet.new(Map.keys(value)) == expected do
      true ->
        proposal =
          struct!(__MODULE__, %{
            assessment_id: value["assessment_id"],
            assessment_digest: value["assessment_digest"],
            project_id: value["project_id"],
            repository_provider: value["repository_provider"],
            repository_id: value["repository_id"],
            root: value["root"],
            base_revision: value["base_revision"],
            instruction_precedence: value["instruction_precedence"],
            commands: value["commands"],
            required_checks: value["required_checks"],
            allowed_scope: value["allowed_scope"],
            gaps: value["gaps"],
            conflicts: value["conflicts"],
            multi_root_blockers: value["multi_root_blockers"],
            proposal_digest: value["proposal_digest"]
          })

        if valid?(proposal), do: {:ok, proposal}, else: {:error, :invalid_proposal}

      _invalid ->
        {:error, :invalid_proposal}
    end
  rescue
    _error -> {:error, :invalid_proposal}
  end

  def from_value(_value), do: {:error, :invalid_proposal}

  @doc "Serializes exactly the minimized proposal fields."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = proposal) do
    proposal
    |> Map.take(@fields)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc "Checks the proposal's normalized shape and content digest."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = proposal) do
    with {:ok, _assessment_id} <- uuid(proposal.assessment_id),
         {:ok, _project_id} <- uuid(proposal.project_id),
         {:ok, root} <- RepositoryBindingPreparation.normalize_root(proposal.root),
         {:ok, base_revision} <- RepositoryBindingPreparation.full_commit(proposal.base_revision),
         {:ok, _assessment_digest} <-
           RepositoryBindingPreparation.digest(proposal.assessment_digest),
         {:ok, _proposal_digest} <- RepositoryBindingPreparation.digest(proposal.proposal_digest),
         {:ok, commands} <- normalize_commands(proposal.commands),
         {:ok, required_checks} <- normalize_commands(proposal.required_checks),
         true <- MapSet.subset?(MapSet.new(required_checks), MapSet.new(commands)),
         {:ok, allowed_scope} <- normalize_scope(proposal.allowed_scope, root, false),
         {:ok, gaps} <- normalize_codes(proposal.gaps),
         {:ok, conflicts} <- normalize_codes(proposal.conflicts),
         {:ok, multi_root_blockers} <-
           normalize_scope(proposal.multi_root_blockers, root, true),
         {:ok, precedence} <- normalize_precedence(proposal.instruction_precedence),
         true <- identifier?(proposal.repository_provider),
         true <- identifier?(proposal.repository_id) do
      values = %{
        assessment_id: proposal.assessment_id,
        assessment_digest: proposal.assessment_digest,
        project_id: proposal.project_id,
        repository_provider: proposal.repository_provider,
        repository_id: proposal.repository_id,
        root: root,
        base_revision: base_revision,
        instruction_precedence: precedence,
        commands: commands,
        required_checks: required_checks,
        allowed_scope: allowed_scope,
        gaps: gaps,
        conflicts: conflicts,
        multi_root_blockers: multi_root_blockers
      }

      Map.take(proposal, Map.keys(values)) == values and
        proposal.proposal_digest == digest(values)
    else
      _invalid -> false
    end
  rescue
    _error -> false
  end

  def valid?(_proposal), do: false

  @doc "Rebinds the proposal to the exact completed assessment before a decision."
  @spec matches_assessment?(term(), term()) :: boolean()
  def matches_assessment?(
        %__MODULE__{} = proposal,
        %RepositoryAssessment{state: "completed"} = assessment
      ) do
    valid?(proposal) and strict_provenanced?(assessment) and
      assessment_fields_match?(proposal, assessment) and
      evidence_supports?(
        assessment,
        proposal.commands,
        proposal.required_checks,
        proposal.allowed_scope,
        proposal.multi_root_blockers
      )
  end

  def matches_assessment?(_proposal, _assessment), do: false

  defp strict_provenanced?(assessment) do
    RepositoryAssessment.strict?(assessment) and
      RepositoryAssessment.cache_provenance_complete?(assessment)
  end

  defp assessment_fields_match?(proposal, assessment) do
    proposal.assessment_id == assessment.id and
      proposal.assessment_digest == assessment_digest(assessment) and
      proposal.project_id == assessment.project_id and
      proposal.repository_provider == assessment.repository_provider and
      proposal.repository_id == assessment.repository_id and
      proposal.root == assessment.root and proposal.base_revision == assessment.commit and
      proposal.instruction_precedence == instruction_precedence(assessment)
  end

  @doc false
  @spec assessment_digest(RepositoryAssessment.t()) :: String.t()
  def assessment_digest(%RepositoryAssessment{} = assessment) do
    assessment
    |> RepositoryAssessment.to_value()
    |> digest()
  end

  defp normalize_input(attrs) do
    allowed_atoms = MapSet.new(@input_fields)
    allowed_strings = MapSet.new(Enum.map(@input_fields, &Atom.to_string/1))
    keys = MapSet.new(Map.keys(attrs))

    cond do
      keys == allowed_atoms -> {:ok, Map.take(attrs, @input_fields)}
      keys == allowed_strings -> {:ok, Map.new(@input_fields, &{&1, attrs[Atom.to_string(&1)]})}
      true -> {:error, :invalid_proposal}
    end
  end

  defp instruction_precedence(%RepositoryAssessment{findings: findings}) when is_list(findings) do
    findings
    |> Enum.filter(&(Map.get(&1, "category") in ~w(instruction contribution)))
    |> Enum.map(fn finding ->
      %{
        "authority" => "repository",
        "category" => Map.fetch!(finding, "category"),
        "path" => Map.fetch!(finding, "path")
      }
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn %{"path" => path} -> {-length(Path.split(path)), path} end)
  end

  defp evidence_supports?(assessment, commands, required_checks, allowed_scope, blockers) do
    findings = assessment.findings || []
    structure = assessment.structure || []
    categories = MapSet.new(findings, &Map.get(&1, "category"))

    paths =
      structure
      |> Enum.filter(&(Map.get(&1, "kind") == "directory"))
      |> MapSet.new(&Map.get(&1, "path"))
      |> MapSet.put(assessment.root)

    command_categories = MapSet.new(~w(instruction contribution manifest check ci))
    check_categories = MapSet.new(~w(instruction contribution check ci))

    (commands == [] or not MapSet.disjoint?(categories, command_categories)) and
      (required_checks == [] or not MapSet.disjoint?(categories, check_categories)) and
      Enum.all?(allowed_scope, &MapSet.member?(paths, &1)) and
      Enum.all?(blockers, &MapSet.member?(paths, &1))
  rescue
    _error -> false
  end

  defp normalize_precedence(precedence)
       when is_list(precedence) and length(precedence) <= @max_items do
    normalized =
      Enum.map(precedence, fn
        %{
          "authority" => "repository",
          "category" => category,
          "path" => path
        } = entry
        when map_size(entry) == 3 and category in ~w(instruction contribution) ->
          with {:ok, normalized_path} <- RepositoryBindingPreparation.normalize_root(path),
               true <- normalized_path != "." do
            %{
              "authority" => "repository",
              "category" => category,
              "path" => normalized_path
            }
          else
            _invalid -> :invalid
          end

        _invalid ->
          :invalid
      end)

    if :invalid in normalized or normalized != Enum.uniq(normalized) or
         normalized !=
           Enum.sort_by(normalized, fn %{"path" => path} -> {-length(Path.split(path)), path} end) do
      {:error, :invalid_proposal}
    else
      {:ok, normalized}
    end
  rescue
    _error -> {:error, :invalid_proposal}
  end

  defp normalize_precedence(_precedence), do: {:error, :invalid_proposal}

  defp normalize_commands(values) when is_list(values) and length(values) <= @max_items do
    normalized = Enum.map(values, &normalize_command/1)

    if :invalid in normalized do
      {:error, :invalid_proposal}
    else
      {:ok, normalized |> Enum.uniq() |> Enum.sort()}
    end
  rescue
    _error -> {:error, :invalid_proposal}
  end

  defp normalize_commands(_values), do: {:error, :invalid_proposal}

  defp normalize_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    if trimmed != "" and byte_size(trimmed) <= @max_command_bytes and String.valid?(trimmed) and
         not String.match?(trimmed, ~r/[\x00-\x1f\x7f]/u) and
         not absolute_path_fragment?(trimmed) and
         not String.match?(trimmed, ~r/(?:token|secret|password|credential|api[_-]?key)\s*=/iu),
       do: trimmed,
       else: :invalid
  end

  defp normalize_command(_command), do: :invalid

  # Commands are opaque managed-runtime values, so rejecting absolute paths is
  # safer than trying to interpret shell quoting. These boundaries cover plain
  # tokens plus values introduced by assignments, flags, quotes, delimiters,
  # redirections, and response-file syntax. Relative paths remain valid.
  defp absolute_path_fragment?(command) do
    String.match?(command, ~r/(?:\A|[^A-Za-z0-9._~\/-])\//u) or
      String.match?(command, ~r/(?:\A|[^A-Za-z0-9._~-])[A-Za-z]:[\\\/]/u) or
      String.match?(command, ~r/(?:\A|[^\\])\\\\[^\\\s]+\\/u)
  end

  defp normalize_codes(values) when is_list(values) and length(values) <= @max_items do
    normalized = Enum.map(values, &normalize_code/1)

    if :invalid in normalized,
      do: {:error, :invalid_proposal},
      else: {:ok, normalized |> Enum.uniq() |> Enum.sort()}
  rescue
    _error -> {:error, :invalid_proposal}
  end

  defp normalize_codes(_values), do: {:error, :invalid_proposal}

  defp normalize_code(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_code()

  defp normalize_code(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    if byte_size(normalized) <= @max_code_bytes and
         Regex.match?(~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z/, normalized),
       do: normalized,
       else: :invalid
  end

  defp normalize_code(_value), do: :invalid

  defp normalize_scope(values, root, allow_empty?)
       when is_list(values) and length(values) <= @max_items do
    normalized =
      Enum.map(values, fn path ->
        with {:ok, candidate} <- RepositoryBindingPreparation.normalize_root(path),
             true <- within_root?(candidate, root) do
          candidate
        else
          _invalid -> :invalid
        end
      end)

    cond do
      :invalid in normalized -> {:error, :invalid_proposal}
      normalized == [] and not allow_empty? -> {:error, :invalid_proposal}
      true -> {:ok, normalized |> Enum.uniq() |> Enum.sort()}
    end
  rescue
    _error -> {:error, :invalid_proposal}
  end

  defp normalize_scope(_values, _root, _allow_empty?), do: {:error, :invalid_proposal}

  defp within_root?(_candidate, "."), do: true

  defp within_root?(candidate, root),
    do: candidate == root or String.starts_with?(candidate, root <> "/")

  defp identifier?(value) do
    is_binary(value) and byte_size(value) in 1..255 and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, value)
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
