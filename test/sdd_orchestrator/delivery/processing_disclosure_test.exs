defmodule SddOrchestrator.Delivery.ProcessingDisclosureTest do
  @moduledoc """
  Proof for start-time processing-boundary disclosure (Task 12).

  An explicit start is only an informed one if the person can see where the
  work runs and whether project content leaves its authoritative store. The
  tests pin the two moments a confirmation is genuinely required — before the
  first run, and again after the disclosed boundary changes — and that a
  routine run in between is not interrupted.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.ProcessingDisclosure
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Repo

  @local [
    execution_location: "this computer",
    agent_provider: "configured-agent",
    model_provider: "configured-model",
    transfers: []
  ]

  @remote [
    execution_location: "remote worker",
    agent_provider: "configured-agent",
    model_provider: "configured-model",
    preview_provider: "configured-preview",
    transfers: ["specifications", "source context"]
  ]

  setup do
    previous = Application.get_env(:sdd_orchestrator, :participation_email_delivery)

    Application.put_env(
      :sdd_orchestrator,
      :participation_email_delivery,
      ParticipationDeliveryDouble
    )

    ParticipationDeliveryDouble.succeed()

    on_exit(fn ->
      if previous do
        Application.put_env(:sdd_orchestrator, :participation_email_delivery, previous)
      else
        Application.delete_env(:sdd_orchestrator, :participation_email_delivery)
      end
    end)

    context = DeliveryFixtures.delivery_project_fixture()

    %{
      context: context,
      project: context.project,
      owner: context.owner_actor,
      participant: context.participant_actor,
      owner_account: context.account
    }
  end

  describe "what is disclosed [AC-36]" do
    test "names the execution location and both providers" do
      disclosure = ProcessingDisclosure.describe(@local)

      assert disclosure.execution_location == "this computer"
      assert disclosure.agent_provider == "configured-agent"
      assert disclosure.model_provider == "configured-model"
      assert disclosure.version == ProcessingDisclosure.disclosure_version()
    end

    test "reports the preview provider only when one is configured" do
      refute ProcessingDisclosure.describe(@local).preview_provider
      assert ProcessingDisclosure.describe(@remote).preview_provider == "configured-preview"
    end

    test "says whether project content leaves its authoritative store" do
      refute ProcessingDisclosure.describe(@local).leaves_authoritative_store
      assert ProcessingDisclosure.describe(@remote).leaves_authoritative_store

      assert ProcessingDisclosure.describe(@remote).transfers == [
               "source context",
               "specifications"
             ]
    end

    test "is stable for one boundary and different for another" do
      assert ProcessingDisclosure.describe(@local).digest ==
               ProcessingDisclosure.describe(@local).digest

      refute ProcessingDisclosure.describe(@local).digest ==
               ProcessingDisclosure.describe(@remote).digest
    end

    test "changing any disclosed field changes the agreement" do
      base = ProcessingDisclosure.describe(@local).digest

      for change <- [
            [execution_location: "somewhere else"],
            [agent_provider: "other-agent"],
            [model_provider: "other-model"],
            [preview_provider: "added-preview"],
            [transfers: ["prompts"]]
          ] do
        changed = ProcessingDisclosure.describe(Keyword.merge(@local, change))

        refute changed.digest == base, "#{inspect(change)} did not change the agreement"
      end
    end

    test "the transfer list order does not change the agreement" do
      one = ProcessingDisclosure.describe(Keyword.put(@local, :transfers, ["a", "b"]))
      other = ProcessingDisclosure.describe(Keyword.put(@local, :transfers, ["b", "a"]))

      assert one.digest == other.digest
    end
  end

  describe "confirming the boundary [AC-36]" do
    test "is required before the first start", %{project: project, owner: owner} do
      refute ProcessingDisclosure.confirmed?(
               project.id,
               owner,
               ProcessingDisclosure.describe(@local)
             )
    end

    test "records what the person was actually shown", %{project: project, owner: owner} do
      disclosure = ProcessingDisclosure.describe(@local)

      assert {:ok, confirmation} =
               ProcessingDisclosure.confirm(project.id, owner, disclosure.digest, disclosure)

      assert confirmation.disclosure_digest == disclosure.digest
      assert confirmation.disclosure_version == disclosure.version
      assert confirmation.confirmed_at
      assert ProcessingDisclosure.confirmed?(project.id, owner, disclosure)
    end

    test "an unchanged boundary does not interrupt a later run", %{
      project: project,
      owner: owner
    } do
      disclosure = ProcessingDisclosure.describe(@local)

      {:ok, _first} =
        ProcessingDisclosure.confirm(project.id, owner, disclosure.digest, disclosure)

      # Rebuilding the disclosure from the same configuration reuses the
      # agreement rather than asking again.
      assert ProcessingDisclosure.confirmed?(
               project.id,
               owner,
               ProcessingDisclosure.describe(@local)
             )
    end

    test "a changed boundary invalidates the earlier confirmation", %{
      project: project,
      owner: owner
    } do
      local = ProcessingDisclosure.describe(@local)
      {:ok, _confirmed} = ProcessingDisclosure.confirm(project.id, owner, local.digest, local)

      remote = ProcessingDisclosure.describe(@remote)

      refute ProcessingDisclosure.confirmed?(project.id, owner, remote)
      assert ProcessingDisclosure.confirmed?(project.id, owner, local)
    end

    test "reconfirming the changed boundary replaces the agreement", %{
      project: project,
      owner: owner
    } do
      local = ProcessingDisclosure.describe(@local)
      {:ok, _first} = ProcessingDisclosure.confirm(project.id, owner, local.digest, local)

      remote = ProcessingDisclosure.describe(@remote)
      {:ok, second} = ProcessingDisclosure.confirm(project.id, owner, remote.digest, remote)

      assert second.disclosure_digest == remote.digest
      assert ProcessingDisclosure.confirmed?(project.id, owner, remote)
      refute ProcessingDisclosure.confirmed?(project.id, owner, local)
      assert Repo.aggregate(ProcessingDisclosure, :count) == 1
    end

    test "a digest that no longer matches the configuration is refused", %{
      project: project,
      owner: owner
    } do
      # The boundary changed while the dialog was open, so the agreement the
      # browser is replaying is for something the person can no longer see.
      assert {:error, :boundary_changed} =
               ProcessingDisclosure.confirm(
                 project.id,
                 owner,
                 ProcessingDisclosure.describe(@local).digest,
                 ProcessingDisclosure.describe(@remote)
               )

      assert Repo.aggregate(ProcessingDisclosure, :count) == 0
    end

    test "each person confirms for themselves", %{
      project: project,
      owner: owner,
      participant: participant
    } do
      disclosure = ProcessingDisclosure.describe(@local)

      {:ok, _owner} =
        ProcessingDisclosure.confirm(project.id, owner, disclosure.digest, disclosure)

      assert ProcessingDisclosure.confirmed?(project.id, owner, disclosure)
      refute ProcessingDisclosure.confirmed?(project.id, participant, disclosure)

      {:ok, _participant} =
        ProcessingDisclosure.confirm(project.id, participant, disclosure.digest, disclosure)

      assert ProcessingDisclosure.confirmed?(project.id, participant, disclosure)
      assert Repo.aggregate(ProcessingDisclosure, :count) == 2
    end

    test "an outsider and a departed participant cannot confirm", %{
      context: context,
      project: project,
      owner_account: owner_account,
      participant: participant
    } do
      disclosure = ProcessingDisclosure.describe(@local)

      assert {:error, :unauthorized} =
               ProcessingDisclosure.confirm(
                 project.id,
                 %{account_id: Ecto.UUID.generate()},
                 disclosure.digest,
                 disclosure
               )

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               ProcessingDisclosure.confirm(
                 project.id,
                 participant,
                 disclosure.digest,
                 disclosure
               )

      assert Repo.aggregate(ProcessingDisclosure, :count) == 0
    end

    test "a departed participant's confirmation stops counting", %{
      context: context,
      project: project,
      owner_account: owner_account,
      participant: participant
    } do
      disclosure = ProcessingDisclosure.describe(@local)

      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(project.id, participant, disclosure.digest, disclosure)

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      refute ProcessingDisclosure.confirmed?(project.id, participant, disclosure)
    end

    test "confirmations are scoped to one project", %{project: project, owner: owner} do
      other = DeliveryFixtures.delivery_project_fixture()
      disclosure = ProcessingDisclosure.describe(@local)

      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(project.id, owner, disclosure.digest, disclosure)

      refute ProcessingDisclosure.confirmed?(other.project.id, other.owner_actor, disclosure)
    end
  end
end
