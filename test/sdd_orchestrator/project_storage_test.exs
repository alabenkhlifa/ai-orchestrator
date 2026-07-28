defmodule SddOrchestrator.ProjectStorageTest do
  @moduledoc """
  Domain proofs for the shared `ProjectStorage` contract: hosted availability is
  identity-gated, device is available only with a valid, unexpired readiness
  receipt bound to the attempt, and the minimized `DeviceStorageReceipt` binding
  round-trips without retaining the raw proof or a device label.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Projects.ProjectOnboardingAttempt
  alias SddOrchestrator.ProjectStorage
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt
  alias SddOrchestrator.ProjectStorage.StorageMode

  @attempt_id "11111111-1111-1111-1111-111111111111"
  @device_workspace_id "22222222-2222-2222-2222-222222222222"

  defp attempt(device_setup) do
    %ProjectOnboardingAttempt{id: @attempt_id, origin_kind: "hosted", device_setup: device_setup}
  end

  defp receipt_map(offset_seconds, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Map.merge(
      %{
        "digest" => "abc123def456",
        "nonce" => "nonce-1",
        "attempt_id" => @attempt_id,
        "device_workspace_id" => @device_workspace_id,
        "issued_at" => DateTime.to_iso8601(now),
        "expires_at" => DateTime.to_iso8601(DateTime.add(now, offset_seconds, :second))
      },
      overrides
    )
  end

  describe "modes and labels" do
    test "offers hosted and device in order" do
      assert ProjectStorage.modes() == [:hosted, :device]
      assert ProjectStorage.label(:hosted) == "In my SDD Orchestrator account"
      assert ProjectStorage.label(:device) == "On this device"
    end

    test "parses mode strings" do
      assert ProjectStorage.parse_mode("hosted") == {:ok, :hosted}
      assert ProjectStorage.parse_mode("device") == {:ok, :device}
      assert ProjectStorage.parse_mode("nope") == :error
    end

    test "normalizes the persisted storage-mode contract" do
      assert StorageMode.values() == ["hosted", "device"]
      assert StorageMode.cast(:hosted) == {:ok, "hosted"}
      assert StorageMode.cast("device") == {:ok, "device"}
      assert StorageMode.cast(:unknown) == :error
    end
  end

  describe "availability/2" do
    test "hosted is always available" do
      assert ProjectStorage.availability(:hosted, attempt(nil)) == :available
      assert ProjectStorage.available?(:hosted, attempt(nil))
    end

    test "device is unavailable without a receipt" do
      assert ProjectStorage.availability(:device, attempt(nil)) ==
               {:unavailable, :device_setup_required}

      refute ProjectStorage.available?(:device, attempt(nil))
    end

    test "device is available with a valid, unexpired receipt bound to the attempt" do
      assert ProjectStorage.availability(:device, attempt(receipt_map(3600))) == :available
      assert ProjectStorage.available?(:device, attempt(receipt_map(3600)))
    end

    test "device is unavailable with an expired receipt" do
      assert ProjectStorage.availability(:device, attempt(receipt_map(-60))) ==
               {:unavailable, :device_setup_required}
    end

    test "device is unavailable when the receipt is bound to another attempt" do
      foreign = receipt_map(3600, %{"attempt_id" => "99999999-9999-9999-9999-999999999999"})

      assert ProjectStorage.availability(:device, attempt(foreign)) ==
               {:unavailable, :device_setup_required}
    end

    test "device is unavailable with a malformed receipt" do
      assert ProjectStorage.availability(:device, attempt(%{"token" => "x"})) ==
               {:unavailable, :device_setup_required}
    end
  end

  describe "DeviceStorageReceipt" do
    test "round-trips through its persisted, minimized map form" do
      map = receipt_map(3600)
      assert {:ok, receipt} = DeviceStorageReceipt.from_map(map)
      assert receipt.digest == "abc123def456"
      assert receipt.attempt_id == @attempt_id
      assert receipt.device_workspace_id == @device_workspace_id
      assert DeviceStorageReceipt.valid?(receipt)

      round_tripped = DeviceStorageReceipt.to_map(receipt)
      assert round_tripped["digest"] == "abc123def456"
      # The minimized form never carries a raw proof or a device label.
      refute Map.has_key?(round_tripped, "token")
      refute Map.has_key?(round_tripped, "device_label")
    end

    test "issue/1 stores only a digest of the raw proof, never the proof itself" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      receipt =
        DeviceStorageReceipt.issue(%{
          token: "raw-secret-proof",
          attempt_id: @attempt_id,
          device_workspace_id: @device_workspace_id,
          nonce: "nonce-1",
          issued_at: now,
          expires_at: DateTime.add(now, 3600, :second)
        })

      refute receipt.digest == "raw-secret-proof"
      refute Enum.member?(Map.values(DeviceStorageReceipt.to_map(receipt)), "raw-secret-proof")
    end

    test "rejects a receipt missing required binding fields" do
      assert DeviceStorageReceipt.from_map(%{"expires_at" => "2030-01-01T00:00:00Z"}) == :error
      assert DeviceStorageReceipt.from_map(%{"digest" => "x"}) == :error
      assert DeviceStorageReceipt.from_map(nil) == :error
    end

    test "an expired receipt is invalid" do
      {:ok, receipt} = DeviceStorageReceipt.from_map(receipt_map(-1))
      refute DeviceStorageReceipt.valid?(receipt)
    end
  end
end
