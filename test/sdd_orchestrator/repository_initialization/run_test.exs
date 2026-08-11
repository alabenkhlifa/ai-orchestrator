defmodule SddOrchestrator.RepositoryInitialization.RunTest do
  @moduledoc """
  Task 4 proof: `Run`'s own defaults and the idempotency-key uniqueness
  business rule (a caller retrying the same run request must be told about
  the collision, not silently succeed twice) — not a re-proof of Ecto's own
  `cast`/`validate_required` mechanics, which `create_changeset/2` otherwise
  just delegates to.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.Run

  setup do
    {:ok, plan} =
      RepositoryInitialization.create_plan(%{
        device_workspace_id: Ecto.UUID.generate(),
        target_reference: WorkerProtocol.generate_id(),
        eligibility: "empty_directory"
      })

    %{plan: plan}
  end

  describe "create_changeset/2" do
    test "defaults to pending state and an empty progress log", %{plan: plan} do
      changeset = Run.create_changeset(%Run{}, base_attrs(plan))

      assert Ecto.Changeset.get_field(changeset, :state) == "pending"
      assert Ecto.Changeset.get_field(changeset, :progress) == []
    end

    test "persists and reloads with the ordered progress shape intact", %{plan: plan} do
      attrs = Map.put(base_attrs(plan), :idempotency_key, WorkerProtocol.generate_id())

      assert {:ok, run} = %Run{} |> Run.create_changeset(attrs) |> Repo.insert()
      assert reloaded = Repo.get!(Run, run.id)
      assert reloaded.progress == []
      assert reloaded.state == "pending"
    end

    test "refuses a second run with the same idempotency key", %{plan: plan} do
      key = WorkerProtocol.generate_id()
      attrs = Map.put(base_attrs(plan), :idempotency_key, key)

      assert {:ok, _first} = %Run{} |> Run.create_changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %Run{}
               |> Run.create_changeset(Map.put(base_attrs(plan), :idempotency_key, key))
               |> Repo.insert()

      assert %{idempotency_key: ["has already been taken"]} = errors_on(changeset)
    end

    test "rejects an unsupported state", %{plan: plan} do
      changeset = Run.create_changeset(%Run{}, Map.put(base_attrs(plan), :state, "archived"))

      assert %{state: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects an unsupported kit choice", %{plan: plan} do
      changeset = Run.create_changeset(%Run{}, Map.put(base_attrs(plan), :kit_choice, "maybe"))

      assert %{kit_choice: ["is invalid"]} = errors_on(changeset)
    end

    test "refuses a plan id that does not reference a real plan" do
      changeset = Run.create_changeset(%Run{}, base_attrs_for_plan_id(Ecto.UUID.generate()))

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{plan_id: [_reason]} = errors_on(changeset)
    end
  end

  describe "progress_changeset/2" do
    test "appends a typed event onto the ordered log", %{plan: plan} do
      {:ok, run} = %Run{} |> Run.create_changeset(base_attrs(plan)) |> Repo.insert()

      event = %{"type" => "progress", "occurred_at" => "2026-08-11T00:00:00Z", "payload" => %{}}

      assert {:ok, updated} = run |> Run.progress_changeset(%{progress: [event]}) |> Repo.update()

      assert updated.progress == [event]
    end
  end

  defp base_attrs(plan), do: base_attrs_for_plan_id(plan.id)

  defp base_attrs_for_plan_id(plan_id) do
    %{
      plan_id: plan_id,
      device_workspace_id: Ecto.UUID.generate(),
      worker_id: Ecto.UUID.generate(),
      dispatch_id: WorkerProtocol.generate_id(),
      idempotency_key: WorkerProtocol.generate_id(),
      state: "pending",
      kit_choice: "declined"
    }
  end
end
