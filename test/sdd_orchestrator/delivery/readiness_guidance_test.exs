defmodule SddOrchestrator.Delivery.ReadinessGuidanceTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.ReadinessGuidance
  alias SddOrchestrator.ReadinessGuidanceDouble, as: Double

  @revision_id "8f2c1a54-7c1e-4a3b-9d20-1b7f6c5e4d33"
  @digest String.duplicate("ab", 32)
  @requirements """
  As a team lead I want a weekly digest of delivered work so I can report progress
  without collecting it by hand.
  """

  describe "configured adapter resolution" do
    test "defaults to the unconfigured stand-in and reports unavailability, not readiness" do
      assert ReadinessGuidance.adapter() == ReadinessGuidance.Unconfigured
      assert ReadinessGuidance.assess(input()) == {:error, :guidance_unavailable}
    end

    test "resolves the module configured for the application" do
      install()

      assert ReadinessGuidance.adapter() == Double
      assert {:ok, _assessment} = ReadinessGuidance.assess(input())
    end

    test "reduces an adapter reason it does not recognize to a plain failure" do
      install({:error, :some_vendor_code})

      assert ReadinessGuidance.assess(input()) == {:error, :guidance_failed}
    end
  end

  describe "minimum input projection" do
    test "sends only the feature title, revision identity, and requirement text" do
      assert {:ok, projected} = ReadinessGuidance.project(feature(), revision())

      assert projected == %{
               "input_version" => ReadinessGuidance.input_version(),
               "feature_title" => "Weekly delivery digest",
               "revision_id" => @revision_id,
               "revision_digest" => @digest,
               "requirements" => @requirements
             }
    end

    test "drops participant, credential, and repository fields the caller happens to hold" do
      assert {:ok, projected} =
               ReadinessGuidance.project(
                 feature(%{id: "feature-1", assignee_display_name: "Sam"}),
                 revision(%{design: "internal design text", tasks: "task list"})
               )

      assert Map.keys(projected) ==
               ~w(feature_title input_version requirements revision_digest revision_id)
    end

    test "refuses a source map carrying a credential- or content-shaped key" do
      for source <- [%{email: "sam@example.com"}, %{api_key: "abc"}, %{stdout: "log"}] do
        assert ReadinessGuidance.project(feature(source), revision()) ==
                 {:error, :excluded_field_rejected}
      end
    end

    test "requires a title, a revision id, a digest, and requirement text" do
      assert ReadinessGuidance.project(%{}, revision()) == {:error, :invalid_feature_title}
      assert ReadinessGuidance.project(feature(), %{}) == {:error, :invalid_revision_id}

      assert ReadinessGuidance.project(feature(), Map.delete(revision(), :digest)) ==
               {:error, :invalid_revision_digest}

      assert ReadinessGuidance.project(feature(), Map.delete(revision(), :requirements)) ==
               {:error, :invalid_requirements}

      assert ReadinessGuidance.project(feature(%{title: "   "}), revision()) ==
               {:error, :invalid_feature_title}
    end

    test "requires a well-formed content digest" do
      assert ReadinessGuidance.project(feature(), revision(%{digest: "not-a-digest"})) ==
               {:error, :invalid_revision_digest}
    end

    test "rejects a non-map source" do
      assert ReadinessGuidance.project("feature", revision()) == {:error, :invalid_guidance_input}
    end

    test "rejects a hand-built projection with a missing or unknown field" do
      assert ReadinessGuidance.assess(Map.delete(input(), "requirements")) ==
               {:error, :missing_input_field}

      assert ReadinessGuidance.assess(Map.put(input(), "repository", "content")) ==
               {:error, :unknown_input_field}

      assert ReadinessGuidance.assess(Map.put(input(), "input_version", 99)) ==
               {:error, :unsupported_input_version}

      assert ReadinessGuidance.assess("not an input") == {:error, :invalid_guidance_input}
    end
  end

  describe "response schema" do
    test "accepts a versioned envelope carrying validated findings" do
      install({:findings, [Double.finding()]})

      assert {:ok, assessment} = ReadinessGuidance.assess(input())

      assert assessment["response_version"] == ReadinessGuidance.response_version()
      assert assessment["revision_id"] == @revision_id
      assert [%{"id" => "missing-success-measure"}] = assessment["findings"]
    end

    test "rejects an unknown response version" do
      install({:response, Map.put(Double.response(@revision_id, []), "response_version", 2)})

      assert ReadinessGuidance.assess(input()) == {:error, :unsupported_response_version}
    end

    test "rejects an envelope with a missing or unknown field" do
      install({:response, Map.delete(Double.response(@revision_id, []), "findings")})
      assert ReadinessGuidance.assess(input()) == {:error, :missing_response_field}

      Double.script({:response, Map.put(Double.response(@revision_id, []), "notes", "extra")})
      assert ReadinessGuidance.assess(input()) == {:error, :unknown_response_field}
    end

    test "rejects an answer about a different revision" do
      install({:response, Double.response("00000000-0000-0000-0000-000000000000", [])})

      assert ReadinessGuidance.assess(input()) == {:error, :revision_binding_mismatch}
    end

    test "rejects a finding with a missing, unknown, or unusable field" do
      cases = [
        {Map.delete(Double.finding(), "explanation"), :missing_finding_field},
        {Map.put(Double.finding(), "severity", "high"), :unknown_finding_field},
        {Double.finding(%{"id" => ""}), :invalid_finding_id},
        {Double.finding(%{"summary" => ""}), :invalid_finding_summary},
        {Double.finding(%{"explanation" => "  "}), :invalid_finding_explanation}
      ]

      install()

      for {finding, reason} <- cases do
        Double.script({:findings, [finding]})
        assert ReadinessGuidance.assess(input()) == {:error, reason}
      end
    end

    test "rejects a duplicate finding id so a blocker cannot be shadowed" do
      install({:findings, [Double.finding(), Double.finding(%{"blocking" => false})]})

      assert ReadinessGuidance.assess(input()) == {:error, :duplicate_finding_id}
    end

    test "rejects findings that are not a list of maps" do
      install({:response, Double.response(@revision_id, "none")})
      assert ReadinessGuidance.assess(input()) == {:error, :invalid_findings}

      Double.script({:findings, ["nothing is missing"]})
      assert ReadinessGuidance.assess(input()) == {:error, :invalid_finding}
    end

    test "rejects an adapter answer that is not a response at all" do
      install({:response, "looks good to me"})
      assert ReadinessGuidance.assess(input()) == {:error, :invalid_guidance_response}

      Double.script({:raw, :ok})
      assert ReadinessGuidance.assess(input()) == {:error, :invalid_guidance_response}
    end
  end

  describe "finding categories" do
    test "accepts missing, ambiguous, and conflicting findings" do
      findings =
        Enum.map(ReadinessGuidance.categories(), fn category ->
          Double.finding(%{"id" => "finding-#{category}", "category" => category})
        end)

      install({:findings, findings})

      assert {:ok, assessment} = ReadinessGuidance.assess(input())

      assert Enum.map(assessment["findings"], & &1["category"]) ==
               ~w(ambiguous conflicting missing)
    end

    test "rejects a category the product does not define" do
      install({:findings, [Double.finding(%{"category" => "stylistic"})]})

      assert ReadinessGuidance.assess(input()) == {:error, :unknown_finding_category}
    end
  end

  describe "blocking classification" do
    test "separates visible blockers from dismissible suggestions" do
      blocker = Double.finding(%{"id" => "missing-scope", "blocking" => true})

      suggestion =
        Double.finding(%{
          "id" => "ambiguous-wording",
          "category" => "ambiguous",
          "blocking" => false,
          "summary" => "The wording of the reminder rule is unclear.",
          "explanation" => "Two readings are possible; naming the intended one would help."
        })

      install({:findings, [blocker, suggestion]})

      assert {:ok, assessment} = ReadinessGuidance.assess(input())
      assert %{blocking: [^blocker], suggestions: [^suggestion]} = classify(assessment)
    end

    test "reports no blockers only when the adapter actually returned none" do
      install({:findings, []})

      assert {:ok, assessment} = ReadinessGuidance.assess(input())
      assert %{blocking: [], suggestions: []} = classify(assessment)
    end

    test "rejects a non-boolean blocking flag instead of guessing it" do
      for value <- ["true", 1, nil] do
        install({:findings, [Double.finding(%{"blocking" => value})]})

        assert ReadinessGuidance.assess(input()) == {:error, :invalid_blocking_flag}
      end
    end
  end

  describe "timeout and provider failure" do
    test "reports a timeout as its own reason and never as an empty assessment" do
      install({:error, :guidance_timeout})

      assert ReadinessGuidance.assess(input()) == {:error, :guidance_timeout}
    end

    test "reports a provider failure distinctly from a timeout" do
      install({:error, :guidance_failed})
      assert ReadinessGuidance.assess(input()) == {:error, :guidance_failed}

      Double.script({:error, :guidance_unavailable})
      assert ReadinessGuidance.assess(input()) == {:error, :guidance_unavailable}
    end
  end

  describe "size limits" do
    test "rejects requirement text larger than the field limit" do
      oversized = String.duplicate("a", ReadinessGuidance.limits()[:max_requirements_bytes] + 1)

      assert ReadinessGuidance.project(feature(), revision(%{requirements: oversized})) ==
               {:error, :invalid_requirements}
    end

    test "rejects a projection whose encoded form exceeds the prompt limit" do
      escaped = String.duplicate("\"", 40_000)

      assert ReadinessGuidance.project(feature(), revision(%{requirements: escaped})) ==
               {:error, :input_too_large}
    end

    test "rejects more findings than the response may carry" do
      findings =
        for index <- 1..(ReadinessGuidance.limits()[:max_findings] + 1) do
          Double.finding(%{"id" => "finding-#{index}"})
        end

      install({:findings, findings})

      assert ReadinessGuidance.assess(input()) == {:error, :too_many_findings}
    end

    test "rejects an oversized explanation and an oversized response" do
      limits = ReadinessGuidance.limits()

      install(
        {:findings,
         [Double.finding(%{"explanation" => text(limits[:max_finding_explanation_bytes] + 1)})]}
      )

      assert ReadinessGuidance.assess(input()) == {:error, :invalid_finding_explanation}

      bulky =
        for index <- 1..40 do
          Double.finding(%{
            "id" => "finding-#{index}",
            "explanation" => text(limits[:max_finding_explanation_bytes])
          })
        end

      Double.script({:findings, bulky})
      assert ReadinessGuidance.assess(input()) == {:error, :response_too_large}
    end
  end

  describe "secret and participant-email exclusion" do
    test "refuses credential material in the requirement text" do
      leaked = "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"

      assert ReadinessGuidance.project(feature(), revision(%{requirements: leaked})) ==
               {:error, :secret_material_rejected}
    end

    test "refuses a credential- or transcript-shaped field in the adapter answer" do
      install({:findings, [Map.put(Double.finding(), "api_key", "abc")]})
      assert ReadinessGuidance.assess(input()) == {:error, :secret_field_rejected}

      Double.script({:findings, [Map.put(Double.finding(), "transcript", "the whole exchange")]})
      assert ReadinessGuidance.assess(input()) == {:error, :excluded_field_rejected}

      Double.script(
        {:findings, [Double.finding(%{"explanation" => "Use -----BEGIN KEY----- here"})]}
      )

      assert ReadinessGuidance.assess(input()) == {:error, :secret_material_rejected}
    end

    test "refuses a participant email address on the way out" do
      assert ReadinessGuidance.project(
               feature(),
               revision(%{requirements: "Notify sam.lee@example.com every Friday."})
             ) == {:error, :participant_email_rejected}
    end

    test "refuses a participant email address on the way back" do
      install(
        {:findings, [Double.finding(%{"explanation" => "Ask sam.lee@example.com about it."})]}
      )

      assert ReadinessGuidance.assess(input()) == {:error, :participant_email_rejected}
    end
  end

  describe "no write-back" do
    test "the guidance boundary calls no repository or persistence function" do
      {:ok, {_module, [imports: imports]}} =
        ReadinessGuidance |> :code.which() |> :beam_lib.chunks([:imports])

      called = imports |> Enum.map(&(&1 |> elem(0) |> Atom.to_string())) |> Enum.uniq()

      refute Enum.any?(
               called,
               &(String.starts_with?(&1, "Elixir.Ecto") or
                   String.starts_with?(&1, "Elixir.SddOrchestrator.Repo"))
             )
    end

    test "returns plain data the caller must persist itself" do
      install({:findings, [Double.finding()]})

      assert {:ok, assessment} = ReadinessGuidance.assess(input())
      refute is_struct(assessment)
      assert Enum.all?(assessment["findings"], &(is_map(&1) and not is_struct(&1)))
    end
  end

  describe "deterministic double" do
    test "records the projection it was asked about and repeats one answer" do
      install({:findings, [Double.finding()]})

      assert {:ok, first} = ReadinessGuidance.assess(input())
      assert {:ok, second} = ReadinessGuidance.assess(input())

      assert first == second
      assert Double.requested() == [input(), input()]
    end

    test "restores the previously configured adapter when the test ends" do
      restore = Double.install()
      assert ReadinessGuidance.adapter() == Double

      restore.()
      assert ReadinessGuidance.adapter() == ReadinessGuidance.Unconfigured
    end
  end

  defp install(script \\ {:findings, []}), do: on_exit(Double.install(script))

  defp classify(assessment), do: ReadinessGuidance.classify(assessment)

  defp feature(attrs \\ %{}), do: Map.merge(%{title: "Weekly delivery digest"}, attrs)

  defp revision(attrs \\ %{}) do
    Map.merge(%{id: @revision_id, digest: @digest, requirements: @requirements}, attrs)
  end

  defp input do
    {:ok, projected} = ReadinessGuidance.project(feature(), revision())

    projected
  end

  defp text(bytes), do: String.duplicate("x", bytes)
end
