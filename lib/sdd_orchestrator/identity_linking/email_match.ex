defmodule SddOrchestrator.IdentityLinking.EmailMatch do
  @moduledoc """
  Conservative canonicalization for automatic identity-link candidate matching.

  Produces a comparison key for an email address, or reports the address as
  ineligible for automatic matching. The key is used only to compare a GitHub
  verified-primary email against passwordless identities; it never rewrites the
  stored verified address.

  Pipeline (business-rule order):

    1. Trim surrounding whitespace and validate structure. Internal whitespace is
       rejected, not repaired.
    2. Require ASCII in both the local part and the domain. A non-ASCII address is
       ineligible; matching never Unicode-normalizes, transliterates, removes
       diacritics, or maps confusables to manufacture a match.
    3. Reject any `xn--` (IDNA ASCII-compatible) domain label, case-insensitively.
       Matching never converts domain forms.
    4. Base normalization: lowercase the domain, preserve local-part case.
    5. Approved provider rules for the exact domain and account type, applied in
       the canonical order — case folding, then dot removal, then `+tag`
       stripping — from `ProviderRegistry`. Unknown and custom domains fail closed
       to base normalization only.

  A comparison key is `"<transformed-local>@<lowercased-domain>"`. Two addresses
  match automatically only when their keys are byte-equal.
  """

  alias SddOrchestrator.IdentityLinking.ProviderRegistry

  @type comparison_key :: String.t()
  @type ineligible_reason :: :invalid | :non_ascii | :idna

  @doc """
  Computes the automatic-matching comparison key for an email.

  Returns `{:ok, key}` for an eligible address or `{:ineligible, reason}` when
  the address must be excluded from automatic matching (`:invalid`,
  `:non_ascii`, or `:idna`). An ineligible address stays a usable separate
  sign-in; it is only excluded from automatic matching.
  """
  @spec comparison_key(term()) :: {:ok, comparison_key()} | {:ineligible, ineligible_reason()}
  def comparison_key(email) when is_binary(email) do
    with {:ok, {local, domain}} <- trim_and_split(email),
         :ok <- ascii_eligible(local, domain),
         :ok <- non_idna(domain) do
      lowered_domain = String.downcase(domain)
      {:ok, apply_rules(local, lowered_domain) <> "@" <> lowered_domain}
    end
  end

  def comparison_key(_), do: {:ineligible, :invalid}

  @doc """
  Returns `true` when two addresses share a comparison key, i.e. they match
  automatically. Ineligible addresses never match (including against each other).
  """
  @spec match?(term(), term()) :: boolean()
  def match?(a, b) do
    case {comparison_key(a), comparison_key(b)} do
      {{:ok, key}, {:ok, key}} -> true
      _ -> false
    end
  end

  # Trim surrounding whitespace, then require exactly one `@` with non-empty,
  # whitespace-free local and domain parts. Anything else is structurally invalid.
  defp trim_and_split(email) do
    trimmed = String.trim(email)

    with true <- Regex.match?(~r/^[^\s@]+@[^\s@]+$/u, trimmed),
         [local, domain] <- String.split(trimmed, "@") do
      {:ok, {local, domain}}
    else
      _ -> {:ineligible, :invalid}
    end
  end

  defp ascii_eligible(local, domain) do
    if ascii?(local) and ascii?(domain), do: :ok, else: {:ineligible, :non_ascii}
  end

  defp ascii?(string) do
    string |> String.to_charlist() |> Enum.all?(&(&1 in 0..127))
  end

  # Reject IDNA ASCII-compatible-encoding labels (`xn--…`) case-insensitively.
  defp non_idna(domain) do
    labels = domain |> String.downcase() |> String.split(".")
    if Enum.any?(labels, &String.starts_with?(&1, "xn--")), do: {:ineligible, :idna}, else: :ok
  end

  # Apply only the approved rules for this exact domain, always in the canonical
  # order: case folding, then dot removal, then `+tag` stripping.
  defp apply_rules(local, lowered_domain) do
    rules = ProviderRegistry.rules_for(lowered_domain)

    local
    |> maybe_case_fold(rules)
    |> maybe_remove_dots(rules)
    |> maybe_strip_tag(rules)
  end

  defp maybe_case_fold(local, rules) do
    if :case_fold in rules, do: String.downcase(local), else: local
  end

  defp maybe_remove_dots(local, rules) do
    if :dot_removal in rules, do: String.replace(local, ".", ""), else: local
  end

  defp maybe_strip_tag(local, rules) do
    if :tag_stripping in rules, do: local |> String.split("+", parts: 2) |> hd(), else: local
  end
end
