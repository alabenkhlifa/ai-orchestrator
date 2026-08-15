defmodule SddOrchestrator.ProjectAssistant.SecretRedactor do
  @moduledoc """
  High-confidence credential, token, private-key, and minimal personal-data
  redaction for assistant model input, answers, and citation excerpts
  (AC-19).

  This is content-level redaction: scanning bytes that were already read or
  composed and masking a detected secret before it crosses a boundary
  (model input, persistence, logging, or citation presentation). It is
  deliberately distinct from `SddOrchestrator.ProjectAssistant.RepositoryExclusions`,
  which denies a *path* before it is ever read at all — a pre-read boundary,
  not a content scan. Both are required: a configured secret path is denied
  outright, and an otherwise-ordinary file or model output that happens to
  contain a secret-shaped value is still redacted here.

  The high-confidence secret patterns are duplicated from, not called into,
  `SddOrchestrator.Portability.PayloadPolicy`'s private `@secret_patterns` —
  that module only detects-and-rejects a whole payload
  (`{:error, :secret_detected}`); this module redacts in place so a
  legitimate answer or excerpt is not discarded wholesale just because one
  substring looks like a credential. Duplication with attribution is this
  codebase's established idiom for an independently-applicable defensive
  constant (see `SddOrchestrator.Privacy.Retention`'s repeated "own named
  window even though the value matches" comments) rather than reaching into
  another specification's private module attribute.

  Personal-data minimization here is deliberately narrow and high-confidence
  only: an email address is the one broadly-recognizable, low-false-positive
  personal-data shape a citation excerpt or model answer could plausibly
  contain (e.g. a code comment, commit trailer, or config file). It is not a
  general PII classifier — a general classifier belongs to a future,
  separately scoped detection capability if evidence shows it is needed;
  this task's owned surface is "credentials, tokens, private keys, and
  unnecessary personal data" filtering at the boundaries this feature
  actually owns, not a new NLP-grade redaction service.
  """

  @redacted_placeholder "[redacted]"

  # Duplicated from `SddOrchestrator.Portability.PayloadPolicy.@secret_patterns`
  # (see moduledoc): private keys, GitHub-shaped tokens, OpenAI-shaped
  # secret keys, AWS access key IDs, bearer tokens, and generic
  # access/refresh/session/pairing token and password/passphrase/
  # client_secret/api_key assignments.
  @secret_patterns [
    ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
    ~r/\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}\b/,
    ~r/\bsk-[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{12,}\b/i,
    ~r/\b(?:access|refresh|session|pairing)[_-]?token\s*[:=]\s*\S+/i,
    ~r/\b(?:password|passphrase|client_secret|api_key)\s*[:=]\s*\S+/i
  ]

  # A conservative email-address shape only: this feature's own minimal
  # unnecessary-personal-data surface, not a general PII scanner.
  @email_pattern ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/

  @all_patterns @secret_patterns ++ [@email_pattern]

  @doc "The placeholder every detected secret or minimized value is replaced with."
  @spec redacted_placeholder() :: String.t()
  def redacted_placeholder, do: @redacted_placeholder

  @doc """
  Redacts every detected credential, token, private key, and email address
  in one string. Returns `nil` unchanged and passes through any non-binary
  value unchanged, so a caller may thread this over an optional field
  without a separate nil-check.
  """
  @spec redact(String.t() | nil) :: String.t() | nil
  def redact(nil), do: nil

  def redact(text) when is_binary(text) do
    Enum.reduce(@all_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted_placeholder)
    end)
  end

  def redact(other), do: other

  @doc "Reports whether the given text contains a high-confidence secret or email pattern."
  @spec secret?(String.t()) :: boolean()
  def secret?(text) when is_binary(text), do: Enum.any?(@all_patterns, &Regex.match?(&1, text))
  def secret?(_other), do: false
end
