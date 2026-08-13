defmodule SddOrchestrator.Privacy.DeliveryContentBoundary do
  @moduledoc """
  One shared, reusable minimum-content contract for every guided-delivery
  boundary (specs/18 Task 3, AC-04).

  Slice 07 already enforces most of AC-04 at each individual boundary, each
  with its own duplicated ad hoc detection logic:
  `SddOrchestrator.Delivery.SecretBoundary` (worker protocol values),
  `SddOrchestrator.Delivery.Comments` (participant comment free text),
  `SddOrchestrator.Delivery.ActivityEntry` (persisted activity payload keys),
  `SddOrchestrator.Delivery.ProtocolCodec` /
  `SddOrchestrator.Delivery.EventIngestion` (the worker normalized-event
  allowlist), and `SddOrchestrator.Delivery.RunNotifications` (notification
  bodies, by construction never touching participant content). This module
  does not replace, wrap, or call into any of that already-approved Slice 07
  product code — it is a read-only dependency for this specification and
  stays entirely outside `lib/sdd_orchestrator/delivery/`.

  What this module adds is the one thing Slice 07 does not have: a single
  place that names the closed vocabulary of what a minimum-content boundary
  refuses, and a single typed refusal result every check returns.

  ## Design choice: mirrored, not called

  `SecretBoundary`'s forbidden-key list and PEM-marker check, and
  `Comments`'s free-text secret and email regex families, are **mirrored**
  here as a privacy-owned copy rather than imported or called. Two reasons:

  1. This task's ownership is explicitly self-contained — it must not modify,
     and should not create a runtime dependency into, `lib/delivery/`.
  2. `SecretBoundary` validates JSON *keys* inside worker protocol envelopes;
     `Comments`'s regex family validates *prose* with no keys at all. A
     shared detector for both shapes needs its own home regardless of which
     existing module it borrows vocabulary from.

  The tradeoff is duplication: if Slice 07 widens its forbidden-key or
  secret-shape vocabulary, this module does not automatically follow. That
  tradeoff is accepted here because this module's job is cross-boundary
  minimization *in addition to* Slice 07's own enforcement, not a replacement
  of it — Slice 07's boundaries keep working even if this module did not
  exist.

  ## What "unauthorized project content" means for this task

  Ordinary project-content boundaries (feature, evidence, and preview access)
  are already enforced by `SddOrchestrator.Delivery.ParticipantGuard`, which
  is Task 2's concern. For this task, "unauthorized project content" is
  scoped to a raw provider event or payload shape reaching somewhere a
  normalized worker event should be instead — see `reject_raw_event/2`.
  """

  alias SddOrchestrator.Privacy.DeliveryContentBoundaryAudit

  # Mirrors SddOrchestrator.Delivery.SecretBoundary's forbidden key vocabulary
  # and PEM marker, and SddOrchestrator.Delivery.Comments's secret-shape
  # regex family, as a privacy-owned copy — see the moduledoc's "Design
  # choice" section.
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

  # Mirrors SddOrchestrator.Delivery.Comments's @email_shape.
  @email_pattern ~r/[\w.+-]+@[\w-]+\.[\w.-]+/

  @type refusal ::
          {:error, :credential_detected}
          | {:error, :email_detected}
          | {:error, :raw_event_detected}

  @doc "The closed credential-shaped key vocabulary this module mirrors from `SecretBoundary`."
  @spec credential_keys() :: [String.t()]
  def credential_keys, do: @credential_keys

  @doc """
  Scans one piece of free text — a comment body, review feedback, a
  notification title, body, or label — for a credential or an email address.

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
  Walks a decoded map/list value — a worker envelope, an activity payload —
  rejecting a forbidden key name or an embedded credential/email shape in any
  string value, at any nesting depth.

  `field` names the top-level field being scanned, for diagnostic logging;
  a nested forbidden key name is logged in its own place instead.
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
  Reports whether a worker envelope carries any key outside the caller's own
  approved allowlist — the raw-provider-event shape a normalized worker event
  must never take.

  `allowed_keys` is supplied by the caller's own protocol schema (for example
  `ProtocolCodec`'s per-envelope-type field lists, proved directly against
  `ProtocolCodec`/`EventIngestion` in this task's tests). This function never
  hardcodes a second copy of that schema — it is a generic "nothing beyond
  what you approved" check, reusable for any allowlisted envelope shape.
  """
  @spec reject_raw_event(map(), [String.t()]) :: :ok | refusal()
  def reject_raw_event(envelope, allowed_keys) when is_map(envelope) do
    case envelope |> Map.keys() |> Enum.reject(&(&1 in allowed_keys)) do
      [] -> :ok
      extra -> refuse(:raw_event_detected, Enum.join(extra, ","))
    end
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
    DeliveryContentBoundaryAudit.event(:refused, %{
      check: reason,
      field: field,
      outcome: :rejected
    })

    {:error, reason}
  end
end
