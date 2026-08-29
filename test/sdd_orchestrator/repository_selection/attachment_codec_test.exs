defmodule SddOrchestrator.RepositorySelection.AttachmentCodecTest do
  @moduledoc """
  Task 2 proof: the wire carries identities and a folder name, and nothing else.

  Both directions are closed on purpose. A request leaves as exactly four
  fields, so nothing a caller happens to hold can ride along, and an answer is
  refused whole when it carries a key this codec does not recognise, so a path
  or a remote cannot reach the control plane even from a worker that decided to
  send one. The bounds are here for the same reason: a real answer is small,
  and an untrusted sender must not be able to make the control plane hold what
  it sent.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositorySelection.AttachmentCodec
  alias SddOrchestrator.RepositorySelection.SelectionRequest

  describe "encode_request/1" do
    test "a request encodes to exactly the four allowed fields" do
      assert {:ok, payload} = AttachmentCodec.encode_request(request())

      assert Enum.sort(Map.keys(payload)) == [
               "candidates",
               "expires_at",
               "generate",
               "request_id"
             ]
    end

    test "candidates encode as string-keyed references and identities" do
      request =
        request(
          candidates: [
            %{ref: "project-a", identity: "local-repo:v1:salt:digest-a"},
            %{ref: :project_b, identity: "local-repo:v1:salt:digest-b"}
          ]
        )

      assert {:ok, payload} = AttachmentCodec.encode_request(request)

      assert payload["candidates"] == [
               %{"ref" => "project-a", "identity" => "local-repo:v1:salt:digest-a"},
               %{"ref" => "project_b", "identity" => "local-repo:v1:salt:digest-b"}
             ]
    end

    test "the request carries its own id, the generate flag, and an ISO 8601 expiry" do
      expires_at = ~U[2026-08-29 10:00:00Z]
      request = request(id: "req-1", generate?: true, expires_at: expires_at)

      assert {:ok, payload} = AttachmentCodec.encode_request(request)
      assert payload["request_id"] == "req-1"
      assert payload["generate"] == true
      assert payload["expires_at"] == "2026-08-29T10:00:00Z"
      assert {:ok, ^expires_at, 0} = DateTime.from_iso8601(payload["expires_at"])
    end

    test "no encoded value spells a location" do
      request =
        request(candidates: [%{ref: "project-a", identity: "local-repo:v1:salt:digest"}])

      assert {:ok, payload} = AttachmentCodec.encode_request(request)
      refute Enum.any?(strings(payload), &String.contains?(&1, "/"))
    end

    test "a reference with no obvious string form is refused" do
      request = request(candidates: [%{ref: %{nested: true}, identity: "local-repo:v1:s:d"}])

      assert {:error, :invalid_request} = AttachmentCodec.encode_request(request)
    end

    test "a candidate that is not a reference and an identity is refused" do
      request = request(candidates: [%{ref: "project-a", identity: :not_a_string}])

      assert {:error, :invalid_request} = AttachmentCodec.encode_request(request)
    end
  end

  describe "encode_cancellation/1" do
    test "a cancellation names the request and nothing else" do
      assert {:ok, payload} = AttachmentCodec.encode_cancellation(request(id: "req-1"))
      assert payload == %{"request_id" => "req-1"}
    end
  end

  describe "decode_result/1" do
    test "a worker's answer decodes to the attributes an answer accepts" do
      payload = %{
        "request_id" => "req-1",
        "outcome" => "selected",
        "folder_name" => "orchestrator",
        "matches" => ["project-a"],
        "identity" => "local-repo:v1:fresh:digest"
      }

      assert {:ok, ^payload} = AttachmentCodec.decode_result(payload)
    end

    test "a refusal answer needs only its id and outcome" do
      payload = %{"request_id" => "req-1", "outcome" => "not_a_git_repository"}

      assert {:ok, ^payload} = AttachmentCodec.decode_result(payload)
    end

    test "an answer carrying a path is refused whole" do
      payload = %{
        "request_id" => "req-1",
        "outcome" => "selected",
        "folder_name" => "orchestrator",
        "path" => "/Users/person/code/orchestrator"
      }

      assert {:error, :invalid_result} = AttachmentCodec.decode_result(payload)
    end

    test "an answer carrying a remote URL is refused whole" do
      payload = %{
        "request_id" => "req-1",
        "outcome" => "selected",
        "remote_url" => "git@example.com:person/orchestrator.git"
      }

      assert {:error, :invalid_result} = AttachmentCodec.decode_result(payload)
    end

    test "an over-long matches list is refused" do
      payload = %{
        "request_id" => "req-1",
        "outcome" => "selected",
        "matches" => Enum.map(1..101, &"project-#{&1}")
      }

      assert {:error, :invalid_result} = AttachmentCodec.decode_result(payload)

      within_bounds = Map.put(payload, "matches", Enum.map(1..100, &"project-#{&1}"))
      assert {:ok, ^within_bounds} = AttachmentCodec.decode_result(within_bounds)
    end

    test "an over-long folder name is refused" do
      payload = %{
        "request_id" => "req-1",
        "outcome" => "selected",
        "folder_name" => String.duplicate("a", 256)
      }

      assert {:error, :invalid_result} = AttachmentCodec.decode_result(payload)

      within_bounds = Map.put(payload, "folder_name", String.duplicate("a", 255))
      assert {:ok, ^within_bounds} = AttachmentCodec.decode_result(within_bounds)
    end

    test "an over-long identity is refused" do
      payload = %{
        "request_id" => "req-1",
        "outcome" => "selected",
        "identity" => String.duplicate("a", 513)
      }

      assert {:error, :invalid_result} = AttachmentCodec.decode_result(payload)

      within_bounds = Map.put(payload, "identity", String.duplicate("a", 512))
      assert {:ok, ^within_bounds} = AttachmentCodec.decode_result(within_bounds)
    end

    test "an answer that is not a map is refused" do
      assert {:error, :invalid_result} = AttachmentCodec.decode_result("selected")
    end
  end

  defp request(overrides \\ []) do
    defaults = [
      id: Ecto.UUID.generate(),
      requester: self(),
      device_workspace_id: Ecto.UUID.generate(),
      worker_id: "wrk_paired_worker",
      candidates: [],
      generate?: false,
      expires_at: DateTime.utc_now()
    ]

    struct!(SelectionRequest, Keyword.merge(defaults, overrides))
  end

  # Every string anywhere in the payload, so a location cannot hide inside a
  # nested candidate.
  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)

  defp strings(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} -> strings(key) ++ strings(nested) end)
  end

  defp strings(_value), do: []
end
