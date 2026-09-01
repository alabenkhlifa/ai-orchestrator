defmodule SddOrchestrator.Delivery.ReadinessGuidance do
  @moduledoc """
  The one configured model boundary that says what a specification still needs.

  Guidance is advice, never authority. The boundary is asked what is missing,
  ambiguous, or conflicting in one exact specification revision and answers with
  a versioned structured finding list. It cannot edit a requirement, resolve a
  blocker, or store anything; the durable readiness assessment belongs to the
  task that owns that record.

  Two rules hold on every call. What leaves the control plane is a minimum
  projection — the feature title, the revision identity, and the requirement
  text — so participant email addresses, credentials, and repository content
  never reach a model provider by construction rather than by filtering. And
  what comes back is validated against an exact schema before it can influence
  readiness: an unknown version, an unknown category, a non-boolean blocking
  flag, an answer about a different revision, an oversized payload, or
  credential- or email-shaped content is rejected rather than trusted.

  A timeout and a provider failure return distinct typed reasons and never an
  empty finding list. An empty finding list means "nothing blocks this feature",
  which is a claim a boundary that failed has not earned.
  """

  alias SddOrchestrator.Delivery.{ActivityEntry, CanonicalJson, SecretBoundary}

  @input_version 1
  @response_version 1

  @categories ~w(ambiguous conflicting missing)
  @input_keys ~w(feature_title input_version requirements revision_digest revision_id)
  @response_keys ~w(findings response_version revision_id)
  @finding_keys ~w(blocking category explanation id summary)

  @max_input_bytes 64 * 1_024
  @max_response_bytes 64 * 1_024
  @max_feature_title_bytes 200
  @max_requirements_bytes 48 * 1_024
  @max_findings 50
  @max_finding_id_bytes 64
  @max_finding_summary_bytes 200
  @max_finding_explanation_bytes 2_000

  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @email_pattern ~r/[[:alnum:]._%+-]+@[[:alnum:]-]+\.[[:alpha:]]{2,}/u

  # Only these reasons survive the boundary. A provider adapter that invents its
  # own error atom is reported as a plain failure, because an unrecognized
  # reason must not reach readiness logic that switches on it.
  #
  # `not_configured` is the one reason that says nothing about this feature. It
  # reports the deployment, so readiness records it as a fact instead of a
  # failed judgement, while every other reason means nobody judged the feature.
  @adapter_reasons ~w(guidance_timeout guidance_unavailable guidance_failed not_configured)a

  @type input :: %{required(String.t()) => term()}
  @type finding :: %{required(String.t()) => term()}
  @type assessment :: %{required(String.t()) => term()}
  @type reason :: atom()

  @callback assess(input :: map()) :: {:ok, map()} | {:error, atom()}

  @spec input_version() :: pos_integer()
  def input_version, do: @input_version

  @spec response_version() :: pos_integer()
  def response_version, do: @response_version

  @spec categories() :: [String.t()]
  def categories, do: @categories

  @spec limits() :: keyword(pos_integer())
  def limits do
    [
      max_input_bytes: @max_input_bytes,
      max_response_bytes: @max_response_bytes,
      max_feature_title_bytes: @max_feature_title_bytes,
      max_requirements_bytes: @max_requirements_bytes,
      max_findings: @max_findings,
      max_finding_id_bytes: @max_finding_id_bytes,
      max_finding_summary_bytes: @max_finding_summary_bytes,
      max_finding_explanation_bytes: @max_finding_explanation_bytes
    ]
  end

  @doc "The configured guidance adapter, defaulting to the unconfigured stand-in."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(
      :sdd_orchestrator,
      :readiness_guidance,
      SddOrchestrator.Delivery.ReadinessGuidance.Unconfigured
    )
  end

  @doc """
  Builds the minimum projection one feature revision sends to the adapter.

  Only these four values leave the control plane. Participants, credentials,
  repository content, run history, and activity are dropped because they are
  never read, and a source map that carries a credential- or content-shaped key
  is refused outright rather than quietly narrowed.
  """
  @spec project(map(), map()) :: {:ok, input()} | {:error, reason()}
  def project(feature, revision) when is_map(feature) and is_map(revision) do
    with :ok <- reject_excluded_keys(feature),
         :ok <- reject_excluded_keys(revision),
         {:ok, title} <- fetch(feature, :title, :invalid_feature_title),
         {:ok, revision_id} <- fetch(revision, :id, :invalid_revision_id),
         {:ok, digest} <- fetch(revision, :digest, :invalid_revision_digest),
         {:ok, requirements} <- fetch(revision, :requirements, :invalid_requirements) do
      input = %{
        "input_version" => @input_version,
        "feature_title" => title,
        "revision_id" => revision_id,
        "revision_digest" => digest,
        "requirements" => requirements
      }

      with :ok <- validate_input(input), do: {:ok, input}
    end
  end

  def project(_feature, _revision), do: {:error, :invalid_guidance_input}

  @doc """
  Asks the configured adapter about one projected revision.

  The projection is revalidated here because a caller may build it by hand, and
  the answer is accepted only when it matches the schema and names the revision
  that was asked about.
  """
  @spec assess(map()) :: {:ok, assessment()} | {:error, reason()}
  def assess(input) when is_map(input) do
    with :ok <- validate_input(input),
         {:ok, response} <- invoke(input) do
      validate_response(response, input)
    end
  end

  def assess(_input), do: {:error, :invalid_guidance_input}

  @doc """
  Splits one validated assessment into visible blockers and dismissible suggestions.

  Only an explicit `true` blocks. A finding whose classification is anything
  else is a suggestion, so a malformed flag can never silently gate a feature.
  """
  @spec classify(assessment()) :: %{blocking: [finding()], suggestions: [finding()]}
  def classify(%{"findings" => findings}) when is_list(findings) do
    {blocking, suggestions} = Enum.split_with(findings, &(&1["blocking"] == true))

    %{blocking: blocking, suggestions: suggestions}
  end

  defp invoke(input) do
    case adapter().assess(input) do
      {:ok, response} when is_map(response) -> {:ok, response}
      {:error, reason} when is_atom(reason) -> {:error, adapter_reason(reason)}
      _unusable -> {:error, :invalid_guidance_response}
    end
  end

  defp adapter_reason(reason) when reason in @adapter_reasons, do: reason
  defp adapter_reason(_reason), do: :guidance_failed

  defp fetch(source, key, reason) do
    case Map.get(source, key, Map.get(source, Atom.to_string(key))) do
      value when is_binary(value) -> {:ok, value}
      _absent -> {:error, reason}
    end
  end

  defp validate_input(input) do
    with :ok <- validate_keys(input, @input_keys, :missing_input_field, :unknown_input_field),
         :ok <-
           validate_version(input["input_version"], @input_version, :unsupported_input_version),
         :ok <-
           validate_text(input["feature_title"], @max_feature_title_bytes, :invalid_feature_title),
         :ok <- validate_id(input["revision_id"], :invalid_revision_id),
         :ok <- validate_digest(input["revision_digest"]),
         :ok <-
           validate_text(input["requirements"], @max_requirements_bytes, :invalid_requirements),
         :ok <- validate_disclosure(input) do
      validate_size(input, @max_input_bytes, :input_too_large, :invalid_guidance_input)
    end
  end

  defp validate_response(response, input) do
    with :ok <-
           validate_keys(
             response,
             @response_keys,
             :missing_response_field,
             :unknown_response_field
           ),
         :ok <-
           validate_version(
             response["response_version"],
             @response_version,
             :unsupported_response_version
           ),
         :ok <- validate_binding(response["revision_id"], input["revision_id"]),
         :ok <-
           validate_size(
             response,
             @max_response_bytes,
             :response_too_large,
             :invalid_guidance_response
           ),
         :ok <- validate_disclosure(response),
         :ok <- validate_findings(response["findings"]) do
      {:ok, response}
    end
  end

  defp validate_binding(answered, asked) do
    if answered == asked, do: :ok, else: {:error, :revision_binding_mismatch}
  end

  defp validate_findings(findings) when is_list(findings) do
    with :ok <- validate_finding_count(findings),
         :ok <- reduce_each(findings, &validate_finding/1) do
      validate_unique_ids(findings)
    end
  end

  defp validate_findings(_findings), do: {:error, :invalid_findings}

  defp validate_finding_count(findings) do
    if length(findings) <= @max_findings, do: :ok, else: {:error, :too_many_findings}
  end

  defp validate_finding(finding) when is_map(finding) do
    with :ok <-
           validate_keys(finding, @finding_keys, :missing_finding_field, :unknown_finding_field),
         :ok <- validate_id(finding["id"], :invalid_finding_id),
         :ok <- validate_category(finding["category"]),
         :ok <- validate_blocking(finding["blocking"]),
         :ok <-
           validate_text(finding["summary"], @max_finding_summary_bytes, :invalid_finding_summary) do
      validate_text(
        finding["explanation"],
        @max_finding_explanation_bytes,
        :invalid_finding_explanation
      )
    end
  end

  defp validate_finding(_finding), do: {:error, :invalid_finding}

  defp validate_unique_ids(findings) do
    ids = Enum.map(findings, &Map.fetch!(&1, "id"))

    if length(ids) == length(Enum.uniq(ids)), do: :ok, else: {:error, :duplicate_finding_id}
  end

  defp validate_category(value) do
    if value in @categories, do: :ok, else: {:error, :unknown_finding_category}
  end

  defp validate_blocking(value) when is_boolean(value), do: :ok
  defp validate_blocking(_value), do: {:error, :invalid_blocking_flag}

  defp validate_keys(value, expected, missing_reason, unknown_reason) do
    actual = value |> Map.keys() |> Enum.sort()

    cond do
      actual == Enum.sort(expected) -> :ok
      Enum.any?(expected, &(&1 not in actual)) -> {:error, missing_reason}
      true -> {:error, unknown_reason}
    end
  end

  defp validate_version(value, expected, reason) do
    if value === expected, do: :ok, else: {:error, reason}
  end

  defp validate_text(value, max_bytes, reason) do
    if is_binary(value) and String.trim(value) != "" and byte_size(value) <= max_bytes,
      do: :ok,
      else: {:error, reason}
  end

  defp validate_id(value, reason) do
    if is_binary(value) and value != "" and byte_size(value) <= @max_finding_id_bytes,
      do: :ok,
      else: {:error, reason}
  end

  defp validate_digest(value) do
    if is_binary(value) and Regex.match?(@digest_pattern, value),
      do: :ok,
      else: {:error, :invalid_revision_digest}
  end

  # The limit applies to the encoded bytes rather than the raw text, because
  # escaping is what a provider actually receives and what a caller could use to
  # push far more through than the field limits suggest.
  defp validate_size(value, max_bytes, oversize_reason, invalid_reason) do
    case CanonicalJson.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      {:ok, _encoded} -> {:error, oversize_reason}
      {:error, _reason} -> {:error, invalid_reason}
    end
  end

  defp validate_disclosure(value) do
    with :ok <- SecretBoundary.validate(value),
         :ok <- reject_excluded_keys(value) do
      reject_email(value)
    end
  end

  # The exclusion set is the union of the credential list and the raw-content
  # list, so a field this slice already refuses to store is also a field it
  # refuses to send to or accept from a model provider.
  defp excluded_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    normalized in ActivityEntry.forbidden_payload_keys() or
      normalized in SecretBoundary.forbidden_keys()
  end

  defp reject_excluded_keys(value) when is_map(value) and not is_struct(value) do
    if Enum.any?(Map.keys(value), &excluded_key?/1) do
      {:error, :excluded_field_rejected}
    else
      value |> Map.values() |> reduce_each(&reject_excluded_keys/1)
    end
  end

  defp reject_excluded_keys(values) when is_list(values),
    do: reduce_each(values, &reject_excluded_keys/1)

  defp reject_excluded_keys(_value), do: :ok

  defp reject_email(value) when is_map(value) and not is_struct(value),
    do: value |> Map.values() |> reduce_each(&reject_email/1)

  defp reject_email(values) when is_list(values), do: reduce_each(values, &reject_email/1)

  defp reject_email(value) when is_binary(value) do
    if Regex.match?(@email_pattern, value),
      do: {:error, :participant_email_rejected},
      else: :ok
  end

  defp reject_email(_value), do: :ok

  defp reduce_each(values, check) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case check.(value) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end

defmodule SddOrchestrator.Delivery.ReadinessGuidance.Unconfigured do
  @moduledoc """
  The default adapter: no guidance provider is configured.

  It never answers with a finding list. An empty list is the shape of "this
  specification is ready", so a deployment without a provider would otherwise
  mark every feature ready without anything having assessed it.

  Its reason is `:not_configured` rather than a failure, because those are
  different things to the person reading the page. A configured provider that
  cannot be reached may work on the next press. A deployment with no provider
  will answer the same way every time, and readiness says so in plain words
  instead of showing an error nobody can act on.
  """
  @behaviour SddOrchestrator.Delivery.ReadinessGuidance

  @impl true
  def assess(_input), do: {:error, :not_configured}
end
