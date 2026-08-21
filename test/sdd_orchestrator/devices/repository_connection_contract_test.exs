defmodule SddOrchestrator.Devices.RepositoryConnectionContractTest do
  @moduledoc """
  Task 5 proof: the minimum outbound metadata contract accepts only the approved
  fields and fails closed on any prohibited, unexpected, or missing field, so no
  local path, remote URL, filename, Git history, or source can leave the device.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.RepositoryConnectionContract, as: Contract

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        connection_id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        worker_id: Ecto.UUID.generate(),
        repository_fingerprint: portable_identifier(),
        status: "connected",
        compatibility: %{
          app_version: "1.2.3",
          protocol_version: "1",
          os_family: "macos",
          os_major: "25"
        }
      },
      overrides
    )
  end

  test "builds from the approved fields and exposes nothing more" do
    assert {:ok, contract} = Contract.build(valid_attrs())
    assert contract.status == "connected"
    assert contract.compatibility.os_family == "macos"

    keys = contract |> Map.from_struct() |> Map.keys() |> MapSet.new()
    prohibited = MapSet.new(Contract.prohibited_fields())
    assert MapSet.disjoint?(keys, prohibited)
  end

  test "rejects each prohibited field at the top level" do
    for field <- [:path, :remote_url, :filename, :git_history, :source, :html_url, :owner] do
      attrs = valid_attrs() |> Map.put(field, "leaked")
      assert {:error, {:prohibited_field, ^field}} = Contract.build(attrs)
    end
  end

  test "rejects prohibited data as a string key too" do
    attrs = valid_attrs() |> Map.put("path", "/Users/someone/secret/repo")
    assert {:error, {:prohibited_field, :path}} = Contract.build(attrs)
  end

  test "rejects a prohibited field hidden inside compatibility" do
    attrs = valid_attrs(%{compatibility: %{os_family: "macos", remote_url: "https://x"}})
    assert {:error, {:prohibited_field, :remote_url}} = Contract.build(attrs)
  end

  test "rejects an unexpected field rather than dropping it" do
    assert {:error, {:unexpected_field, _}} =
             Contract.build(Map.put(valid_attrs(), :extra_thing, "x"))

    assert {:error, {:unexpected_compatibility_field, _}} =
             Contract.build(valid_attrs(%{compatibility: %{os_family: "macos", cpu: "arm"}}))
  end

  test "requires the mandatory identity and status fields" do
    assert {:error, {:missing_field, :repository_fingerprint}} =
             Contract.build(Map.delete(valid_attrs(), :repository_fingerprint))

    assert {:error, {:missing_field, :workspace_id}} =
             Contract.build(Map.put(valid_attrs(), :workspace_id, ""))
  end

  test "requires a strict portable repository identity" do
    legacy =
      :crypto.mac(:hmac, :sha256, "workspace", "root")
      |> Base.url_encode64(padding: false)

    assert PortableRepositoryIdentity.legacy_identifier?(legacy)

    assert {:error, :invalid_repository_fingerprint} =
             Contract.build(valid_attrs(%{repository_fingerprint: legacy}))

    assert {:error, :invalid_repository_fingerprint} =
             Contract.build(valid_attrs(%{repository_fingerprint: "local-repo:v1:malformed"}))
  end

  test "accepts only the approved connection statuses" do
    for status <- Contract.statuses() do
      assert {:ok, _} = Contract.build(valid_attrs(%{status: status}))
    end

    assert {:error, {:invalid_status, "uploaded"}} =
             Contract.build(valid_attrs(%{status: "uploaded"}))
  end

  test "compatibility may be omitted" do
    assert {:ok, contract} = Contract.build(Map.delete(valid_attrs(), :compatibility))
    assert contract.compatibility == %{}
  end

  defp portable_identifier do
    salt = Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)
    digest = Base.url_encode64(:binary.copy(<<2>>, 32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
