defmodule SddOrchestrator.IdentityLinking.ProviderRegistryTest do
  @moduledoc """
  Proof for the versioned provider-rule registry: the Gmail-only launch set,
  exact-domain scoping, account-type scope, cited evidence, and fail-closed
  behavior for every unlisted domain.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.IdentityLinking.ProviderRegistry

  test "the launch registry is versioned" do
    assert ProviderRegistry.version() == 1
  end

  test "the launch registry contains only Gmail personal accounts" do
    domains = ProviderRegistry.entries() |> Enum.flat_map(& &1.domains) |> Enum.sort()
    assert domains == ["gmail.com", "googlemail.com"]

    assert Enum.all?(ProviderRegistry.entries(), &(&1.account_type == :personal))
  end

  test "every entry cites official provider evidence and an account-type scope" do
    for entry <- ProviderRegistry.entries() do
      assert is_binary(entry.evidence) and entry.evidence =~ "http"
      assert entry.account_type in [:personal, :organizational]
      assert entry.rules != []
    end
  end

  test "Gmail enables case folding, dot removal, and +tag stripping" do
    assert ProviderRegistry.rules_for("gmail.com") == [:case_fold, :dot_removal, :tag_stripping]

    assert ProviderRegistry.rules_for("googlemail.com") == [
             :case_fold,
             :dot_removal,
             :tag_stripping
           ]
  end

  test "unlisted domains (including Workspace and custom) get no alias rules" do
    assert ProviderRegistry.rules_for("company.example") == []
    assert ProviderRegistry.rules_for("outlook.com") == []
    # A Google Workspace domain must not inherit Gmail's personal rules.
    assert ProviderRegistry.rules_for("acme.com") == []
  end
end
