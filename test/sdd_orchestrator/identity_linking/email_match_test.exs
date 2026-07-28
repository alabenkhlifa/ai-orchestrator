defmodule SddOrchestrator.IdentityLinking.EmailMatchTest do
  @moduledoc """
  Unit and property proofs for conservative automatic-match canonicalization:
  whitespace handling, domain and local-part case, the approved Gmail dot/tag
  rules, custom-domain fail-closed behavior, non-ASCII and IDNA exclusion, and
  the collision mechanism that later produces ambiguity.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SddOrchestrator.IdentityLinking.EmailMatch

  describe "base normalization" do
    test "trims surrounding whitespace, lowercases the domain, preserves local case" do
      assert {:ok, "User.Name@example.com"} =
               EmailMatch.comparison_key("  User.Name@Example.COM  ")
    end

    test "local parts differing only by case stay distinct on an unapproved domain" do
      assert {:ok, "User@example.com"} = EmailMatch.comparison_key("User@example.com")
      assert {:ok, "user@example.com"} = EmailMatch.comparison_key("user@example.com")
      refute EmailMatch.match?("User@example.com", "user@example.com")
    end

    test "internal whitespace is rejected rather than repaired" do
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("us er@example.com")
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("user@exa mple.com")
    end

    test "structurally invalid addresses are ineligible" do
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("no-at-sign")
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("two@@at.com")
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("@example.com")
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("user@")
      assert {:ineligible, :invalid} = EmailMatch.comparison_key("")
      assert {:ineligible, :invalid} = EmailMatch.comparison_key(nil)
    end
  end

  describe "approved Gmail personal rules (case fold, dot removal, +tag stripping)" do
    test "dot and tag variations of the same Gmail mailbox match" do
      assert EmailMatch.match?("first.last+work@gmail.com", "firstlast@gmail.com")
      assert {:ok, "firstlast@gmail.com"} = EmailMatch.comparison_key("first.last+work@gmail.com")
    end

    test "case folding applies for Gmail" do
      assert {:ok, "firstlast@gmail.com"} = EmailMatch.comparison_key("First.Last@gmail.com")
      assert EmailMatch.match?("First.Last@gmail.com", "firstlast@gmail.com")
    end

    test "googlemail.com carries the same personal rules" do
      assert {:ok, "firstlast@googlemail.com"} =
               EmailMatch.comparison_key("First.Last+tag@googlemail.com")
    end
  end

  describe "custom and unknown domains fail closed" do
    test "personal-domain rules are not inherited by a custom domain" do
      refute EmailMatch.match?("first.last+work@custom.example", "firstlast@custom.example")

      assert {:ok, "first.last+work@custom.example"} =
               EmailMatch.comparison_key("first.last+work@custom.example")
    end

    test "a Google Workspace (custom) domain uses base normalization only" do
      # Same spelling as Gmail's mailbox rules, but on a custom domain: no dot or
      # tag transformation, and local case is preserved.
      assert {:ok, "First.Last+tag@company.example"} =
               EmailMatch.comparison_key("First.Last+tag@Company.Example")
    end
  end

  describe "internationalized address exclusion" do
    test "a non-ASCII local part is ineligible without transformation" do
      assert {:ineligible, :non_ascii} = EmailMatch.comparison_key("café@example.com")
    end

    test "a non-ASCII domain is ineligible" do
      assert {:ineligible, :non_ascii} = EmailMatch.comparison_key("user@café.com")
    end

    test "an xn-- (IDNA) domain label is excluded case-insensitively" do
      assert {:ineligible, :idna} = EmailMatch.comparison_key("user@xn--caf-dma.com")
      assert {:ineligible, :idna} = EmailMatch.comparison_key("user@XN--caf-dma.com")
      assert {:ineligible, :idna} = EmailMatch.comparison_key("user@sub.xn--caf-dma.com")
    end

    test "ineligible addresses never match, including against each other" do
      refute EmailMatch.match?("café@example.com", "café@example.com")
    end
  end

  describe "ambiguity mechanism" do
    test "two distinct Gmail spellings canonicalize to the same key" do
      # This shared key is what candidate resolution (Task 4) treats as ambiguous
      # when it matches more than one hosted identity.
      assert EmailMatch.comparison_key("j.o.h.n@gmail.com") ==
               EmailMatch.comparison_key("john+news@gmail.com")
    end
  end

  ## Property-based invariants

  property "the comparison key is deterministic" do
    check all(email <- ascii_email()) do
      assert EmailMatch.comparison_key(email) == EmailMatch.comparison_key(email)
    end
  end

  property "domain case never changes the comparison key" do
    check all(local <- local_gen(), domain <- domain_gen()) do
      lower = EmailMatch.comparison_key("#{local}@#{domain}")
      upper = EmailMatch.comparison_key("#{local}@#{String.upcase(domain)}")
      assert lower == upper
    end
  end

  property "unapproved domains preserve the local part verbatim and lowercase the domain" do
    check all(local <- local_gen(), domain <- custom_domain_gen()) do
      assert {:ok, key} = EmailMatch.comparison_key("#{local}@#{domain}")
      assert key == "#{local}@#{String.downcase(domain)}"
    end
  end

  property "any non-ASCII character makes the address ineligible" do
    check all(local <- local_gen(), domain <- custom_domain_gen(), accent <- accented_gen()) do
      assert {:ineligible, :non_ascii} = EmailMatch.comparison_key("#{accent}#{local}@#{domain}")
    end
  end

  property "Gmail dots and a single +tag do not change the mailbox key" do
    check all(local <- gmail_local_gen(), tag <- local_gen()) do
      dotted = local |> String.graphemes() |> Enum.join(".")
      canonical = String.downcase(local)

      assert {:ok, "#{canonical}@gmail.com"} ==
               EmailMatch.comparison_key("#{dotted}+#{tag}@gmail.com")
    end
  end

  # Generators: ASCII, whitespace-free, `@`-free parts that never start with xn--.
  defp local_gen, do: string_gen(?a..?z, 1, 8)
  defp gmail_local_gen, do: string_gen(?a..?z, 1, 8)

  defp domain_gen do
    gen all(label <- string_gen(?a..?z, 1, 8), tld <- member_of(["com", "org", "net", "io"])) do
      "#{label}.#{tld}"
    end
  end

  # A custom (unlisted) domain: labels of plain letters never collide with the
  # Gmail launch entry.
  defp custom_domain_gen do
    gen all(label <- string_gen(?a..?z, 3, 8), tld <- member_of(["example", "test", "corp"])) do
      "#{label}.#{tld}"
    end
  end

  defp ascii_email do
    gen(all(local <- local_gen(), domain <- domain_gen(), do: "#{local}@#{domain}"))
  end

  defp accented_gen, do: member_of(["é", "ñ", "ü", "ø", "ç", "π"])

  defp string_gen(range, min, max) do
    range
    |> Enum.to_list()
    |> Enum.map(&<<&1>>)
    |> member_of()
    |> list_of(min_length: min, max_length: max)
    |> map(&Enum.join/1)
  end
end
