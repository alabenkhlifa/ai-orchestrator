defmodule SddOrchestrator.ProjectStorageTest do
  @moduledoc """
  Domain proofs for the shared `ProjectStorage` contract: hosted is always
  available, device is available only with a valid unexpired readiness receipt,
  and the `DeviceStorageReceipt` validation and serialization round-trip.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Projects.ProjectOnboardingAttempt
  alias SddOrchestrator.ProjectStorage
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt
  alias SddOrchestrator.ProjectStorage.StorageMode

  defp attempt(device_setup), do: %ProjectOnboardingAttempt{device_setup: device_setup}

  defp receipt_map(offset_seconds) do
    expires = DateTime.utc_now() |> DateTime.add(offset_seconds, :second) |> DateTime.to_iso8601()
    %{"token" => "opaque-receipt", "expires_at" => expires, "device_label" => "Laptop"}
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

    test "device is available with a valid, unexpired receipt" do
      assert ProjectStorage.availability(:device, attempt(receipt_map(3600))) == :available
      assert ProjectStorage.available?(:device, attempt(receipt_map(3600)))
    end

    test "device is unavailable with an expired receipt" do
      assert ProjectStorage.availability(:device, attempt(receipt_map(-60))) ==
               {:unavailable, :device_setup_required}
    end

    test "device is unavailable with a malformed receipt" do
      assert ProjectStorage.availability(:device, attempt(%{"token" => "x"})) ==
               {:unavailable, :device_setup_required}
    end
  end

  describe "DeviceStorageReceipt" do
    test "round-trips through its persisted map form" do
      map = receipt_map(3600)
      assert {:ok, receipt} = DeviceStorageReceipt.from_map(map)
      assert receipt.token == "opaque-receipt"
      assert receipt.device_label == "Laptop"
      assert DeviceStorageReceipt.valid?(receipt)
      assert DeviceStorageReceipt.to_map(receipt)["token"] == "opaque-receipt"
    end

    test "rejects a receipt without a token or expiry" do
      assert DeviceStorageReceipt.from_map(%{"expires_at" => "2030-01-01T00:00:00Z"}) == :error
      assert DeviceStorageReceipt.from_map(%{"token" => "x"}) == :error
      assert DeviceStorageReceipt.from_map(nil) == :error
    end

    test "an expired receipt is invalid" do
      {:ok, receipt} = DeviceStorageReceipt.from_map(receipt_map(-1))
      refute DeviceStorageReceipt.valid?(receipt)
    end
  end
end
