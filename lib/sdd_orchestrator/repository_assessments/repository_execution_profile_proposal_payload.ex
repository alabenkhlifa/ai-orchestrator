defmodule SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfileProposalPayload do
  @moduledoc """
  Cache-stable managed-runtime proposal fields derived inside the worker.

  Raw repository content is accepted only while deriving the minimized value
  and is never retained. The resulting payload is bound to Task 9's reusable
  cache key and completed-evidence digest, so assessment-specific identifiers
  are deliberately excluded.
  """

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessmentCacheProvenance,
    RepositoryAssessmentCommand,
    RepositoryAssessmentResult,
    RepositoryBindingPreparation
  }

  @version 1
  @proposal_fields [
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers
  ]
  @fields [
    :version,
    :cache_key_sha256,
    :evidence_sha256,
    :commands,
    :required_checks,
    :allowed_scope,
    :gaps,
    :conflicts,
    :multi_root_blockers,
    :payload_digest
  ]
  @gap_codes ~w(missing_project_commands missing_repository_instructions missing_required_checks)
  @conflict_codes ~w(ambiguous_command_evidence)
  @max_items 64
  @max_command_bytes 1_024
  @known_command ~r/\A(?:mix|npm|pnpm|yarn|bun|cargo|go|make|just|task|mvn|gradle|\.\/gradlew|bundle exec|python(?:3)? -m|pytest|tox|deno|composer)(?:\s|\z)/u
  @check_words ~r/(?:\A|[\s:_-])(?:test|tests|check|checks|lint|format|verify|verification|dialyzer|credo|audit|sobelow)(?:\z|[\s:_-])/iu

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          version: pos_integer(),
          cache_key_sha256: String.t(),
          evidence_sha256: String.t(),
          commands: [String.t()],
          required_checks: [String.t()],
          allowed_scope: [String.t()],
          gaps: [String.t()],
          conflicts: [String.t()],
          multi_root_blockers: [String.t()],
          payload_digest: String.t()
        }

  @doc "Derives one strict payload while exact high-signal content is worker-local."
  @spec derive(RepositoryAssessmentCommand.t(), RepositoryAssessmentResult.t(), list()) ::
          {:ok, t()} | {:error, :invalid_proposal_payload}
  def derive(
        %RepositoryAssessmentCommand{} = command,
        %RepositoryAssessmentResult{status: "completed"} = result,
        evidence
      )
      when is_list(evidence) do
    with true <- RepositoryAssessmentCommand.valid?(command),
         true <- RepositoryAssessmentResult.valid?(result),
         true <- RepositoryAssessmentResult.matches_command?(result, command),
         {:ok, evidence} <- validate_evidence(evidence, result),
         {:ok, attrs} <- derive_fields(command, result, evidence),
         {:ok, payload} <- new(result, attrs) do
      {:ok, payload}
    else
      _invalid -> {:error, :invalid_proposal_payload}
    end
  rescue
    _error -> {:error, :invalid_proposal_payload}
  end

  def derive(_command, _result, _evidence), do: {:error, :invalid_proposal_payload}

  @doc "Builds one payload from already minimized six-field proposal data."
  @spec new(RepositoryAssessmentResult.t(), map()) ::
          {:ok, t()} | {:error, :invalid_proposal_payload}
  def new(%RepositoryAssessmentResult{status: "completed"} = result, attrs) when is_map(attrs) do
    with true <- RepositoryAssessmentResult.valid?(result),
         {:ok, attrs} <- normalize_attrs(attrs, result.root),
         {:ok, cache_key_sha256} <- RepositoryAssessmentCacheProvenance.cache_key_sha256(result),
         {:ok, evidence_sha256} <- RepositoryAssessmentCacheProvenance.evidence_sha256(result) do
      values =
        attrs
        |> Map.put(:version, @version)
        |> Map.put(:cache_key_sha256, cache_key_sha256)
        |> Map.put(:evidence_sha256, evidence_sha256)

      {:ok, struct!(__MODULE__, Map.put(values, :payload_digest, digest(values)))}
    else
      _invalid -> {:error, :invalid_proposal_payload}
    end
  rescue
    _error -> {:error, :invalid_proposal_payload}
  end

  def new(_result, _attrs), do: {:error, :invalid_proposal_payload}

  @doc "Confirms the payload is the exact cache-stable value for a current command/result pair."
  @spec valid_for?(term(), term(), term()) :: boolean()
  def valid_for?(
        %__MODULE__{} = payload,
        %RepositoryAssessmentCommand{} = command,
        %RepositoryAssessmentResult{status: "completed"} = result
      ) do
    RepositoryAssessmentCommand.valid?(command) and
      RepositoryAssessmentResult.valid?(result) and
      RepositoryAssessmentResult.matches_command?(result, command) and
      valid_for_result?(payload, result)
  rescue
    _error -> false
  end

  def valid_for?(_payload, _command, _result), do: false

  @doc false
  @spec valid_for_result?(term(), term()) :: boolean()
  def valid_for_result?(
        %__MODULE__{} = payload,
        %RepositoryAssessmentResult{status: "completed"} = result
      ) do
    attrs = Map.take(payload, @proposal_fields)
    RepositoryAssessmentResult.valid?(result) and match?({:ok, ^payload}, new(result, attrs))
  rescue
    _error -> false
  end

  def valid_for_result?(_payload, _result), do: false

  @doc "Returns only the six managed-runtime proposal fields."
  @spec proposal_fields(t()) :: map()
  def proposal_fields(%__MODULE__{} = payload), do: Map.take(payload, @proposal_fields)

  @doc "Serializes the strict minimized worker-local value."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = payload) do
    payload
    |> Map.take(@fields)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc false
  @spec result_sha256(RepositoryAssessmentResult.t()) :: String.t()
  def result_sha256(%RepositoryAssessmentResult{} = result) do
    result
    |> RepositoryAssessmentResult.to_value()
    |> then(&digest({:completed_result, &1}))
  end

  defp validate_evidence(evidence, result) do
    normalized = Enum.map(evidence, &validate_evidence_entry(&1, result.findings))

    cond do
      :invalid in normalized ->
        {:error, :invalid_proposal_payload}

      length(normalized) != length(result.findings) ->
        {:error, :invalid_proposal_payload}

      normalized != Enum.uniq_by(normalized, &{&1.category, &1.path}) ->
        {:error, :invalid_proposal_payload}

      true ->
        {:ok, Enum.sort_by(normalized, &{&1.path, &1.category})}
    end
  end

  defp validate_evidence_entry(
         %{category: category, path: path, content: content} = entry,
         findings
       )
       when map_size(entry) == 3 and is_binary(category) and is_binary(path) and
              is_binary(content) do
    sha256 = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    finding =
      Enum.find(findings, fn finding ->
        finding["category"] == category and finding["path"] == path
      end)

    if String.valid?(content) and is_map(finding) and finding["bytes"] == byte_size(content) and
         finding["sha256"] == sha256 and finding["line_count"] == line_count(content) do
      %{category: category, path: path, content: content}
    else
      :invalid
    end
  end

  defp validate_evidence_entry(_entry, _findings), do: :invalid

  defp derive_fields(command, result, evidence) do
    signals = Enum.map(evidence, &commands_from_evidence/1)

    commands = signals |> Enum.flat_map(& &1.commands) |> normalize_commands()
    required_checks = signals |> Enum.flat_map(& &1.required_checks) |> normalize_commands()
    required_checks = Enum.filter(required_checks, &(&1 in commands))

    gaps =
      []
      |> maybe_add(commands == [], "missing_project_commands")
      |> maybe_add(required_checks == [], "missing_required_checks")
      |> maybe_add(
        Enum.all?(evidence, &(&1.category not in ~w(instruction contribution))),
        "missing_repository_instructions"
      )
      |> Enum.sort()

    conflicts =
      signals
      |> Enum.any?(& &1.ambiguous?)
      |> then(&if(&1, do: ["ambiguous_command_evidence"], else: []))

    {:ok,
     %{
       commands: commands,
       required_checks: required_checks,
       allowed_scope: [command.root],
       gaps: gaps,
       conflicts: conflicts,
       multi_root_blockers: multi_root_blockers(command.root, result.findings)
     }}
  end

  defp commands_from_evidence(%{category: "manifest", path: path, content: content}) do
    if String.downcase(Path.basename(path)) == "package.json" do
      package_commands(content)
    else
      empty_signal()
    end
  end

  defp commands_from_evidence(%{category: "check", path: path, content: content}) do
    basename = String.downcase(Path.basename(path))

    cond do
      basename == "makefile" -> make_commands(content)
      basename == "justfile" -> recipe_commands(content, "just")
      basename in ["taskfile.yml", "taskfile.yaml"] -> taskfile_commands(content)
      true -> empty_signal()
    end
  end

  defp commands_from_evidence(%{category: "ci", content: content}), do: ci_commands(content)

  defp commands_from_evidence(%{category: category, content: content})
       when category in ~w(instruction contribution),
       do: inline_commands(content)

  defp commands_from_evidence(_evidence), do: empty_signal()

  defp package_commands(content) do
    case Jason.decode(content) do
      {:ok, %{"scripts" => scripts}} when is_map(scripts) ->
        Enum.reduce(scripts, empty_signal(), fn {name, body}, signal ->
          command = "npm run #{name}"

          cond do
            not safe_script_name?(name) or not is_binary(body) ->
              %{signal | ambiguous?: true}

            not safe_script_body?(body) ->
              %{signal | ambiguous?: true}

            true ->
              add_command(signal, command, check_name?(name) or check_command?(body))
          end
        end)

      {:ok, _other} ->
        empty_signal()

      {:error, _decode} ->
        %{empty_signal() | ambiguous?: true}
    end
  end

  defp make_commands(content) do
    recipes = recipe_blocks(content, ~r/^([A-Za-z0-9][A-Za-z0-9_.-]*):(?:\s|$)/u)

    Enum.reduce(recipes, empty_signal(), fn {name, body}, signal ->
      if safe_script_body?(body),
        do: add_command(signal, "make #{name}", check_name?(name)),
        else: %{signal | ambiguous?: true}
    end)
  end

  defp recipe_commands(content, tool) do
    recipes = recipe_blocks(content, ~r/^([A-Za-z0-9][A-Za-z0-9_.-]*)(?:\s*\([^)]*\))?:\s*$/u)

    Enum.reduce(recipes, empty_signal(), fn {name, body}, signal ->
      if safe_script_body?(body),
        do: add_command(signal, "#{tool} #{name}", check_name?(name)),
        else: %{signal | ambiguous?: true}
    end)
  end

  defp taskfile_commands(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({empty_signal(), false}, fn line, {signal, in_tasks?} ->
      cond do
        Regex.match?(~r/^tasks:\s*$/u, line) ->
          {signal, true}

        in_tasks? and Regex.match?(~r/^\S/u, line) ->
          {signal, false}

        in_tasks? ->
          case Regex.run(~r/^  ([A-Za-z0-9][A-Za-z0-9_.-]*):\s*$/u, line) do
            [_, name] -> {add_command(signal, "task #{name}", check_name?(name)), true}
            _other -> {signal, true}
          end

        true ->
          {signal, false}
      end
    end)
    |> elem(0)
  end

  defp ci_commands(content) do
    content
    |> String.split("\n")
    |> Enum.reduce(empty_signal(), fn line, signal ->
      candidate =
        case Regex.run(~r/^\s*(?:-\s*)?(?:run:\s*)?([^#].*)$/u, line) do
          [_, value] -> ci_candidate(line, String.trim(value))
          _other -> nil
        end

      cond do
        is_nil(candidate) -> signal
        safe_command?(candidate) -> add_command(signal, candidate, true)
        command_like?(candidate) -> %{signal | ambiguous?: true}
        true -> signal
      end
    end)
  end

  defp ci_candidate(line, value) do
    cond do
      Regex.match?(~r/^\s*(?:-\s*)?run:\s*/u, line) ->
        value

      Regex.match?(
        ~r/^\s*-\s+(?:mix|npm|pnpm|yarn|bun|cargo|go|make|just|task|mvn|gradle|\.\/gradlew|bundle|python|python3|pytest|tox|deno|composer)\b/u,
        line
      ) ->
        value

      true ->
        nil
    end
  end

  defp inline_commands(content) do
    Regex.scan(~r/`([^`\n]+)`/u, content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reduce(empty_signal(), fn candidate, signal ->
      cond do
        safe_command?(candidate) -> add_command(signal, candidate, check_command?(candidate))
        command_like?(candidate) -> %{signal | ambiguous?: true}
        true -> signal
      end
    end)
  end

  defp recipe_blocks(content, header_pattern) do
    {blocks, current} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {blocks, current} ->
        case Regex.run(header_pattern, line) do
          [_, name] ->
            blocks = if current, do: [current | blocks], else: blocks
            {blocks, {name, ""}}

          _other ->
            case current do
              {name, body} -> {blocks, {name, body <> "\n" <> line}}
              nil -> {blocks, nil}
            end
        end
      end)

    blocks = if current, do: [current | blocks], else: blocks
    Enum.reverse(blocks)
  end

  defp add_command(signal, command, required?) do
    normalized = normalize_command(command)

    if normalized do
      %{
        signal
        | commands: [normalized | signal.commands],
          required_checks:
            if(required?, do: [normalized | signal.required_checks], else: signal.required_checks)
      }
    else
      %{signal | ambiguous?: true}
    end
  end

  defp empty_signal, do: %{commands: [], required_checks: [], ambiguous?: false}

  defp normalize_attrs(attrs, root) do
    with true <- MapSet.new(Map.keys(attrs)) == MapSet.new(@proposal_fields),
         {:ok, commands} <- validate_commands(attrs.commands),
         {:ok, required_checks} <- validate_commands(attrs.required_checks),
         true <- MapSet.subset?(MapSet.new(required_checks), MapSet.new(commands)),
         {:ok, allowed_scope} <- validate_paths(attrs.allowed_scope, root, false),
         {:ok, gaps} <- validate_codes(attrs.gaps, @gap_codes),
         {:ok, conflicts} <- validate_codes(attrs.conflicts, @conflict_codes),
         {:ok, multi_root_blockers} <- validate_paths(attrs.multi_root_blockers, root, true),
         true <- commands == [] == "missing_project_commands" in gaps,
         true <- required_checks == [] == "missing_required_checks" in gaps do
      {:ok,
       %{
         commands: commands,
         required_checks: required_checks,
         allowed_scope: allowed_scope,
         gaps: gaps,
         conflicts: conflicts,
         multi_root_blockers: multi_root_blockers
       }}
    else
      _invalid -> {:error, :invalid_proposal_payload}
    end
  end

  defp validate_commands(values) when is_list(values) and length(values) <= @max_items do
    normalized = Enum.map(values, &normalize_command/1)

    if nil in normalized or normalized != Enum.uniq(normalized) or
         normalized != Enum.sort(normalized),
       do: {:error, :invalid_proposal_payload},
       else: {:ok, normalized}
  end

  defp validate_commands(_values), do: {:error, :invalid_proposal_payload}

  defp normalize_commands(values) do
    values
    |> Enum.map(&normalize_command/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_items)
  end

  defp normalize_command(command) when is_binary(command) do
    normalized = command |> String.trim() |> String.replace(~r/\s+/u, " ")
    if safe_command?(normalized), do: normalized, else: nil
  end

  defp normalize_command(_command), do: nil

  defp safe_command?(command) do
    is_binary(command) and command != "" and byte_size(command) <= @max_command_bytes and
      String.valid?(command) and Regex.match?(@known_command, command) and
      not String.match?(command, ~r/[\x00-\x1f\x7f;&|><`]/u) and
      not String.contains?(command, ["$(", "${"]) and
      not absolute_path_fragment?(command) and not credential_assignment?(command)
  end

  defp command_like?(command), do: is_binary(command) and Regex.match?(@known_command, command)

  defp safe_script_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/u, name)

  defp safe_script_body?(body) when is_binary(body) do
    String.valid?(body) and
      not String.match?(body, ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f;&|><`]/u) and
      not String.contains?(body, ["$(", "${"]) and not absolute_path_fragment?(body) and
      not credential_assignment?(body) and
      not Regex.match?(~r/(?:\A|\s)(?:rm|touch|curl|wget|sh|bash|powershell)(?:\s|\z)/iu, body)
  end

  defp safe_script_body?(_body), do: false

  defp credential_assignment?(value),
    do: String.match?(value, ~r/(?:token|secret|password|credential|api[_-]?key)\s*=/iu)

  defp absolute_path_fragment?(value) do
    String.match?(value, ~r/(?:\A|[^A-Za-z0-9._~\/-])\//u) or
      String.match?(value, ~r/(?:\A|[^A-Za-z0-9._~-])[A-Za-z]:[\\\/]/u) or
      String.match?(value, ~r/(?:\A|[^\\])\\\\[^\\\s]+\\/u)
  end

  defp check_name?(name), do: Regex.match?(@check_words, name)
  defp check_command?(command), do: Regex.match?(@check_words, command)

  defp validate_codes(values, allowed)
       when is_list(values) and length(values) <= @max_items do
    if values == Enum.uniq(values) and values == Enum.sort(values) and
         Enum.all?(values, &(&1 in allowed)),
       do: {:ok, values},
       else: {:error, :invalid_proposal_payload}
  end

  defp validate_codes(_values, _allowed), do: {:error, :invalid_proposal_payload}

  defp validate_paths(values, root, allow_empty?)
       when is_list(values) and length(values) <= @max_items do
    normalized =
      Enum.map(values, fn value ->
        with {:ok, path} <- RepositoryBindingPreparation.normalize_root(value),
             true <- within_root?(path, root) do
          path
        else
          _invalid -> :invalid
        end
      end)

    cond do
      :invalid in normalized -> {:error, :invalid_proposal_payload}
      normalized == [] and not allow_empty? -> {:error, :invalid_proposal_payload}
      normalized != Enum.uniq(normalized) -> {:error, :invalid_proposal_payload}
      normalized != Enum.sort(normalized) -> {:error, :invalid_proposal_payload}
      true -> {:ok, normalized}
    end
  end

  defp validate_paths(_values, _root, _allow_empty?),
    do: {:error, :invalid_proposal_payload}

  defp within_root?(_path, "."), do: true
  defp within_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp multi_root_blockers(root, findings) do
    roots =
      findings
      |> Enum.filter(&(&1["category"] == "manifest"))
      |> Enum.map(&project_root(root, &1["path"]))
      |> Enum.uniq()
      |> Enum.sort()

    if length(roots) > 1, do: Enum.reject(roots, &(&1 == root)), else: []
  end

  defp project_root(root, path) do
    relative = Path.dirname(path)

    cond do
      relative == "." -> root
      root == "." -> relative
      true -> Path.join(root, relative)
    end
  end

  defp maybe_add(values, true, value), do: [value | values]
  defp maybe_add(values, false, _value), do: values

  defp line_count(""), do: 0

  defp line_count(content) do
    newline_count = length(:binary.matches(content, "\n"))
    if String.ends_with?(content, "\n"), do: newline_count, else: newline_count + 1
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
