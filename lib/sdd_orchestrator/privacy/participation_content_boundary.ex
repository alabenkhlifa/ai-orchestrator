defmodule SddOrchestrator.Privacy.ParticipationContentBoundary do
  @moduledoc """
  One shared, reusable minimum-content and destination-allowlist contract for
  every participation boundary (specs/26 Task 4, AC-04).

  AC-04 requires that "credentials, secrets, unauthorized project content,
  out-of-context participant emails, and unrelated identities are rejected or
  removed before the boundary is crossed" wherever participation data crosses
  a persistence, notification, delivery, support, logging, export, or
  processor boundary. specs/25 and specs/08 already shape most participation
  write paths narrowly — `SddOrchestrator.Participation.ParticipationEmail`
  and `SddOrchestrator.Participation.ProjectNotifications` both build their
  output from closed field allowlists rather than free text,
  `SddOrchestrator.Participation.ProjectInvitation` never persists a raw
  credential, and `SddOrchestrator.Privacy.ParticipationSupportAudit`
  (specs/26 Task 3) already keeps the support boundary allowlisted. What this
  module adds is the one thing none of those has: a single place that names
  the closed vocabulary of what a minimum-content boundary refuses, a single
  typed refusal result every check returns, and a destination-allowlist check
  cross-referenced against `SddOrchestrator.Privacy.ParticipationProcessingInventory`.

  ## Design choice: mirrored, not called

  `SddOrchestrator.Privacy.DeliveryContentBoundary` (specs/18 Task 3) already
  solved the free-text and structure-scanning half of this problem for
  guided-delivery boundaries. This module **mirrors** that module's
  credential-key vocabulary, credential-pattern family, and email-pattern
  family as a privacy-owned copy rather than importing or calling it. Three
  reasons:

  1. This task's ownership is explicitly self-contained — specs/26's
     `tasks.md` `Requires:` list does not declare a dependency on specs/18's
     `capability` surface, so a runtime call from this module into
     `DeliveryContentBoundary` would be an undeclared cross-specification
     dependency.
  2. The credential-key vocabulary and regex families are generic detection
     primitives, not delivery-specific ones — they belong to whichever
     boundary needs them, duplicated, not centralized behind a dependency
     edge that was never agreed.
  3. Participation's own destination-allowlist need (a field's approved
     processor and transfer classification) has no delivery-boundary
     equivalent at all — `DeliveryContentBoundary` has no such check, so it
     could not be reused for that part even if the text/structure scanners
     were imported.

  The tradeoff is duplication: if specs/18 widens its credential-shape
  vocabulary, this module does not automatically follow. That tradeoff is
  accepted here for the same reason specs/18 accepted it against Slice 07:
  this module's job is cross-boundary minimization for participation
  specifically, not a shared library both specifications must jointly own.

  ## What "unauthorized project content" means for participation

  Participation has no project content of its own — no specifications,
  features, comments, or evidence ever reach a participation schema or
  message. The closest thing participation has to attacker-influenced free
  text is a display name
  (`SddOrchestrator.Participation.DisplayName.normalize/1`), which already
  rejects email-shaped values but does not scan for a credential shape. This
  module's `scan_text/2` is the complementary check: proof in this task's
  test suite demonstrates that a credential-shaped display name is accepted,
  unmodified, by the real `DisplayName`/`ProjectMemberProfile` boundary (a
  documented gap, mirroring specs/18's own documented `ReviewDecision` gap),
  while `scan_text/2` would have caught it before that value reaches a
  notification's `actor_label`. Participation has no raw-provider-event
  concept the way guided delivery does, so this module has no
  `reject_raw_event/2` equivalent.

  ## Destination allowlist

  Every participation field's approved destination is already classified by
  `SddOrchestrator.Privacy.ParticipationProcessingInventory` — every field is
  `:hosted_database` (`:no_transfer`) except
  `ProjectInvitation.delivery_email` and
  `ParticipationEmailDelivery.recipient_address`, which are the only two
  fields classified `:email_delivery_provider` (`:configured_email_delivery`).
  `authorize_destination/3` cross-references that inventory directly rather
  than keeping a second copy of the allowlist, so a future inventory change
  is automatically reflected here.
  """

  alias SddOrchestrator.Privacy.{
    ParticipationContentBoundaryAudit,
    ParticipationProcessingInventory,
    ParticipationProcessingRecord
  }

  # Mirrors SddOrchestrator.Privacy.DeliveryContentBoundary's credential-key
  # vocabulary and regex families as a privacy-owned copy — see the
  # moduledoc's "Design choice" section. Generic detection primitives, not
  # delivery-specific ones.
  @credential_keys ~w(
    access_token
    api_key
    apikey
    authorization
    client_secret
    cookie
    credential
    credentials
    id_token
    passphrase
    password
    private_key
    refresh_token
    secret
    secret_key
    session_token
    ssh_key
    token
  )

  @pem_marker "-----BEGIN "

  @credential_patterns [
    ~r/\bsk-[A-Za-z0-9]{16,}/,
    ~r/\bghp_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/\bAKIA[0-9A-Z]{16}\b/
  ]

  @email_pattern ~r/[\w.+-]+@[\w-]+\.[\w.-]+/

  @type refusal ::
          {:error, :credential_detected}
          | {:error, :email_detected}
          | {:error, :unapproved_destination}
          | {:error, :unclassified_field}

  @doc "The closed credential-shaped key vocabulary this module mirrors from `DeliveryContentBoundary`."
  @spec credential_keys() :: [String.t()]
  def credential_keys, do: @credential_keys

  @doc """
  Scans one piece of free text — a display name, notification title, body, or
  label, or an email subject/body — for a credential or an email address.

  `field` names the scanned field for diagnostic logging only; it is never
  echoed with the matched content. A non-binary input is not text and always
  passes.
  """
  @spec scan_text(term(), String.t()) :: :ok | refusal()
  def scan_text(text, field \\ "text")

  def scan_text(text, field) when is_binary(text) do
    cond do
      credential_shaped?(text) -> refuse(:credential_detected, field)
      email_shaped?(text) -> refuse(:email_detected, field)
      true -> :ok
    end
  end

  def scan_text(_not_text, _field), do: :ok

  @doc """
  Walks a decoded map/list value — a notification event, an email context —
  rejecting a forbidden key name or an embedded credential/email shape in any
  string value, at any nesting depth.

  `field` names the top-level field being scanned, for diagnostic logging; a
  nested forbidden key name is logged in its own place instead.
  """
  @spec scan_structure(term(), String.t()) :: :ok | refusal()
  def scan_structure(value, field \\ "value")

  def scan_structure(value, _field) when is_map(value) and not is_struct(value) do
    case Enum.find(Map.keys(value), &forbidden_key?/1) do
      nil -> value |> Map.to_list() |> scan_pairs()
      key -> refuse(:credential_detected, to_string(key))
    end
  end

  def scan_structure(value, field) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case scan_structure(item, field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def scan_structure(value, field) when is_binary(value), do: scan_text(value, field)
  def scan_structure(_value, _field), do: :ok

  @doc """
  Authorizes one classified participation field crossing to `destination`.

  Cross-references `ParticipationProcessingInventory.records/0` for the
  `{entity, field}` pair: the field's own `processor_category` must equal
  `destination`, or the crossing is refused. A field with no inventory
  classification at all is refused as `:unclassified_field` rather than
  silently allowed — an unclassified field can never authorize a transfer.
  """
  @spec authorize_destination(atom(), atom(), ParticipationProcessingRecord.processor_category()) ::
          :ok | refusal()
  def authorize_destination(entity, field, destination)
      when is_atom(entity) and is_atom(field) and is_atom(destination) do
    case find_record(entity, field) do
      nil -> refuse(:unclassified_field, "#{entity}.#{field}")
      %ParticipationProcessingRecord{processor_category: ^destination} -> :ok
      %ParticipationProcessingRecord{} -> refuse(:unapproved_destination, "#{entity}.#{field}")
    end
  end

  defp find_record(entity, field) do
    Enum.find(
      ParticipationProcessingInventory.records(),
      &(&1.entity == entity and &1.field == field)
    )
  end

  defp scan_pairs(pairs) do
    Enum.reduce_while(pairs, :ok, fn {key, value}, :ok ->
      case scan_structure(value, to_string(key)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp forbidden_key?(key) when is_binary(key), do: String.downcase(key) in @credential_keys
  defp forbidden_key?(key) when is_atom(key), do: forbidden_key?(Atom.to_string(key))
  defp forbidden_key?(_key), do: false

  defp credential_shaped?(text) do
    String.contains?(text, @pem_marker) or
      Enum.any?(@credential_patterns, &Regex.match?(&1, text))
  end

  defp email_shaped?(text), do: Regex.match?(@email_pattern, text)

  defp refuse(reason, field) do
    ParticipationContentBoundaryAudit.event(:refused, %{
      check: reason,
      field: field,
      outcome: :rejected
    })

    {:error, reason}
  end
end
