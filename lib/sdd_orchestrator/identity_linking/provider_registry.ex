defmodule SddOrchestrator.IdentityLinking.ProviderRegistry do
  @moduledoc """
  Versioned registry of exact-domain, account-type-scoped email alias rules used
  only for automatic identity-link candidate matching.

  Provider email semantics are security-sensitive and not globally safe: SMTP
  assigns local-part meaning to the receiving host (RFC 5321), so alias rules are
  approved per exact domain and account type, never inferred. At launch the
  registry contains only Gmail personal accounts (`gmail.com`, `googlemail.com`),
  for which Google documents case-insensitive local parts, dot-insignificance,
  and `+tag` support. Every other domain — including Google Workspace and other
  custom domains — uses base normalization only and fails closed for alias
  matching.

  Governance: the registry is versioned; each entry cites official provider
  documentation and an account-type scope. Adding, changing, or removing an entry
  is a governed change (security review, version bump, audit entry, rollback
  supported), not an implementation default. That is why the registry lives in
  code as the single source of truth: a change is a reviewed code change.

  Alias rules affect comparison only. They never rewrite the stored verified
  address used for display, communication, or rights workflows.
  """

  @typedoc "An approved alias transformation. Applied in the canonical order."
  @type rule :: :case_fold | :dot_removal | :tag_stripping

  @typedoc "One governed registry entry, scoped to exact domains and one account type."
  @type entry :: %{
          domains: [String.t()],
          account_type: :personal | :organizational,
          rules: [rule()],
          evidence: String.t()
        }

  # Bump on every governed change so callers and audits can pin the rule set.
  @version 1

  @entries [
    %{
      domains: ["gmail.com", "googlemail.com"],
      account_type: :personal,
      rules: [:case_fold, :dot_removal, :tag_stripping],
      evidence: "https://support.google.com/mail/answer/7436150"
    }
  ]

  @doc "The current registry version. Increments on every governed change."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The full set of governed registry entries."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc """
  Returns the approved alias rules for a lowercased domain, or `[]` when the
  domain is not registered. Order in the returned list is not significant;
  `EmailMatch` always applies rules in the canonical sequence.
  """
  @spec rules_for(String.t()) :: [rule()]
  def rules_for(domain) when is_binary(domain) do
    case Enum.find(@entries, &(domain in &1.domains)) do
      nil -> []
      entry -> entry.rules
    end
  end
end
