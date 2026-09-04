defmodule SddOrchestrator.RepositoryScan.AttachmentCodecTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryScan.AttachmentCodec
  alias SddOrchestrator.RepositoryScan.ScanAnswer
  alias SddOrchestrator.RepositoryScan.ScanRequest

  @digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit String.duplicate("c", 40)
  @sha256 String.duplicate("d", 64)

  describe "encode_request/1" do
    test "leaves as exactly four fields, one of them the command's own value" do
      request = request()

      assert {:ok, payload} = AttachmentCodec.encode_request(request)

      assert Map.keys(payload) |> Enum.sort() ==
               ~w(command expires_at request_id selection_ref)

      assert payload["request_id"] == request.id
      assert payload["selection_ref"] == request.selection_ref
      assert payload["command"] == RepositoryAssessmentCommand.to_value(request.command)
      assert payload["expires_at"] == DateTime.to_iso8601(request.expires_at)
    end

    test "carries no absolute path, remote url, or file content" do
      assert {:ok, payload} = AttachmentCodec.encode_request(request())

      for value <- string_values(payload) do
        refute String.starts_with?(value, "/"), "#{value} is an absolute path"
        refute String.starts_with?(value, "~"), "#{value} is a home-relative path"
        refute String.contains?(value, "://"), "#{value} is a url"
      end
    end

    test "refuses a request whose command is not a valid command" do
      request = request()

      assert {:error, :invalid_request} =
               AttachmentCodec.encode_request(%{
                 request
                 | command: %{request.command | limits: %{}}
               })

      assert {:error, :invalid_request} =
               AttachmentCodec.encode_request(%{request | command: %{}})
    end

    test "refuses a request missing an id, a selection, or an expiry" do
      request = request()

      assert {:error, :invalid_request} = AttachmentCodec.encode_request(%{request | id: ""})
      assert {:error, :invalid_request} = AttachmentCodec.encode_request(%{request | id: nil})

      assert {:error, :invalid_request} =
               AttachmentCodec.encode_request(%{request | selection_ref: nil})

      assert {:error, :invalid_request} =
               AttachmentCodec.encode_request(%{request | expires_at: "soon"})
    end
  end

  describe "encode_cancellation/1" do
    test "names the request and nothing more" do
      request = request()

      assert {:ok, %{"request_id" => id}} = AttachmentCodec.encode_cancellation(request)
      assert id == request.id
      assert {:ok, payload} = AttachmentCodec.encode_cancellation(request)
      assert map_size(payload) == 1
    end

    test "refuses a request with no id" do
      assert {:error, :invalid_request} =
               AttachmentCodec.encode_cancellation(%{request() | id: nil})
    end
  end

  describe "decode_result/1" do
    test "passes a recognised answer through to the answer boundary" do
      payload = scanned_payload()

      assert {:ok, ^payload} = AttachmentCodec.decode_result(payload)
      assert {:ok, answer} = ScanAnswer.new(payload)
      assert answer.outcome == :scanned
    end

    test "refuses the whole payload for one unrecognised key" do
      assert {:error, :invalid_result} =
               scanned_payload()
               |> Map.put("path", "/Users/someone/code/repository")
               |> AttachmentCodec.decode_result()
    end

    test "refuses an answer larger than one the domain could store" do
      oversized = String.duplicate("x", AttachmentCodec.max_payload_bytes())

      assert {:error, :invalid_result} =
               scanned_payload()
               |> Map.put("reason", oversized)
               |> AttachmentCodec.decode_result()
    end

    test "refuses anything that is not a map" do
      assert {:error, :invalid_result} = AttachmentCodec.decode_result("scanned")
      assert {:error, :invalid_result} = AttachmentCodec.decode_result(nil)
    end
  end

  describe "ScanAnswer.new/1" do
    test "rebuilds the evidence with atom keys, which is the shape the domain validates" do
      assert {:ok, answer} = ScanAnswer.new(scanned_payload())

      assert answer.findings == [
               %{
                 category: "check",
                 path: "Makefile",
                 bytes: 12,
                 sha256: @sha256,
                 line_count: 2
               }
             ]

      assert answer.structure == [%{path: "Makefile", kind: "file"}]
      assert answer.stats == %{discovered_paths: 4, inspected_files: 1, bytes_read: 12}
      assert answer.provenance == %{source: "fresh_scan", cache_stored: true}

      assert answer.proposal == %{
               commands: ["make test"],
               required_checks: ["make test"],
               allowed_scope: ["."],
               gaps: [],
               conflicts: [],
               multi_root_blockers: []
             }
    end

    test "refuses an unknown key inside a finding, a structure entry, or the proposal" do
      assert {:error, :invalid_result} =
               ScanAnswer.new(
                 put_in(scanned_payload(), ["findings"], [
                   %{"category" => "check", "absolute_path" => "/Users/someone/Makefile"}
                 ])
               )

      assert {:error, :invalid_result} =
               ScanAnswer.new(
                 put_in(scanned_payload(), ["structure"], [%{"path" => "Makefile", "size" => 12}])
               )

      assert {:error, :invalid_result} =
               ScanAnswer.new(
                 put_in(scanned_payload(), ["proposal"], %{"commands" => [], "env" => []})
               )

      assert {:error, :invalid_result} =
               ScanAnswer.new(
                 put_in(scanned_payload(), ["stats"], %{"bytes_read" => 1, "cwd" => "/"})
               )
    end

    test "refuses a scanned answer missing any evidence field" do
      for key <- ~w(findings structure stats proposal provenance) do
        assert {:error, :invalid_result} =
                 scanned_payload() |> Map.delete(key) |> ScanAnswer.new()
      end
    end

    test "refuses an evidence field of the wrong kind" do
      assert {:error, :invalid_result} =
               ScanAnswer.new(put_in(scanned_payload(), ["findings"], %{}))

      assert {:error, :invalid_result} =
               ScanAnswer.new(put_in(scanned_payload(), ["stats"], []))

      assert {:error, :invalid_result} =
               ScanAnswer.new(put_in(scanned_payload(), ["findings"], ["Makefile"]))
    end

    test "accepts every refusal reason the bounded scanner can end with" do
      for reason <- ScanAnswer.refusal_reasons() do
        assert {:ok, answer} =
                 ScanAnswer.new(%{
                   "request_id" => "request-1",
                   "outcome" => "refused",
                   "reason" => Atom.to_string(reason)
                 })

        assert answer.reason == reason
      end
    end

    test "refuses an outcome or a reason it does not recognise" do
      assert {:error, :invalid_result} =
               ScanAnswer.new(%{"request_id" => "request-1", "outcome" => "partially_scanned"})

      assert {:error, :invalid_result} =
               ScanAnswer.new(%{
                 "request_id" => "request-1",
                 "outcome" => "refused",
                 "reason" => "disk_full"
               })

      assert {:error, :invalid_result} =
               ScanAnswer.new(%{"request_id" => "request-1", "outcome" => "refused"})
    end

    test "takes a cancellation with no evidence, and needs a request id" do
      assert {:ok, %ScanAnswer{outcome: :cancelled, findings: nil, proposal: nil}} =
               ScanAnswer.new(%{"request_id" => "request-1", "outcome" => "cancelled"})

      assert {:error, :invalid_result} = ScanAnswer.new(%{"outcome" => "cancelled"})

      assert {:error, :invalid_result} =
               ScanAnswer.new(%{"request_id" => 1, "outcome" => "cancelled"})

      assert {:error, :invalid_result} = ScanAnswer.new("cancelled")
    end
  end

  defp request do
    %ScanRequest{
      id: Ecto.UUID.generate(),
      requester: self(),
      device_workspace_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      worker_id: Ecto.UUID.generate(),
      selection_ref: Ecto.UUID.generate(),
      command: command(),
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }
  end

  defp command do
    assessment =
      struct!(RepositoryAssessment, %{
        id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        repository_provider: "local",
        repository_id: "repository-42",
        root: ".",
        commit: @commit,
        scanner_contract_digest: @digest,
        disclosure_digest: @disclosure_digest,
        worker_ref: Ecto.UUID.generate(),
        state: RepositoryAssessment.pending_state()
      })

    {:ok, command} =
      RepositoryAssessmentCommand.new(assessment, RepositoryAssessmentCommand.default_limits())

    command
  end

  defp string_values(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&string_values/1)

  defp string_values(value) when is_list(value), do: Enum.flat_map(value, &string_values/1)
  defp string_values(value) when is_binary(value), do: [value]
  defp string_values(_value), do: []

  defp scanned_payload do
    %{
      "request_id" => "request-1",
      "outcome" => "scanned",
      "findings" => [
        %{
          "category" => "check",
          "path" => "Makefile",
          "bytes" => 12,
          "sha256" => @sha256,
          "line_count" => 2
        }
      ],
      "structure" => [%{"path" => "Makefile", "kind" => "file"}],
      "stats" => %{"discovered_paths" => 4, "inspected_files" => 1, "bytes_read" => 12},
      "provenance" => %{"source" => "fresh_scan", "cache_stored" => true},
      "proposal" => %{
        "commands" => ["make test"],
        "required_checks" => ["make test"],
        "allowed_scope" => ["."],
        "gaps" => [],
        "conflicts" => [],
        "multi_root_blockers" => []
      }
    }
  end
end
