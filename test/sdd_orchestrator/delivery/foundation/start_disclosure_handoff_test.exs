defmodule SddOrchestrator.Delivery.Foundation.StartDisclosureHandoffTest do
  @moduledoc """
  Handoff proof for `capability:guided-delivery-start-disclosure` (Task 54).

  Deployment governance validates a deployment's privacy evidence against the
  boundary this disclosure names. What that child may rely on is pinned here:
  the disclosure describes the execution location, both providers, the preview
  path, and whether content leaves its authoritative store; its digest is the
  agreement, changed by any disclosed field and by nothing else; a confirmation
  binds a person to exactly that digest and is invalidated the moment the
  boundary changes; and the whole boundary is read from one configured seam.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.ProcessingDisclosure
  alias SddOrchestrator.DeliveryFixtures

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
    context = DeliveryFixtures.delivery_project_fixture()

    %{
      project: context.project,
      owner: context.owner_actor,
      participant: context.participant_actor
    }
  end

  describe "the published disclosure contract" do
    test "describes every boundary a deployment profile must evidence" do
      disclosure = ProcessingDisclosure.describe(@remote)

      assert disclosure.version == ProcessingDisclosure.disclosure_version()
      assert disclosure.execution_location == "remote worker"
      assert disclosure.agent_provider == "configured-agent"
      assert disclosure.model_provider == "configured-model"
      assert disclosure.preview_provider == "configured-preview"
      assert disclosure.leaves_authoritative_store
      assert disclosure.transfers == ["source context", "specifications"]
      assert is_binary(disclosure.digest)

      local = ProcessingDisclosure.describe(@local)
      refute local.preview_provider
      refute local.leaves_authoritative_store
    end

    test "the digest is the agreement: every disclosed field changes it, order does not" do
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

      one = ProcessingDisclosure.describe(Keyword.put(@local, :transfers, ["a", "b"]))
      other = ProcessingDisclosure.describe(Keyword.put(@local, :transfers, ["b", "a"]))
      assert one.digest == other.digest
    end

    test "the boundary is read from the one configured seam" do
      previous = Application.get_env(:sdd_orchestrator, :processing_boundary)
      Application.put_env(:sdd_orchestrator, :processing_boundary, @remote)

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, :processing_boundary, previous)
        else
          Application.delete_env(:sdd_orchestrator, :processing_boundary)
        end
      end)

      assert ProcessingDisclosure.configured() == @remote
      assert ProcessingDisclosure.describe().execution_location == "remote worker"

      assert ProcessingDisclosure.describe().digest ==
               ProcessingDisclosure.describe(@remote).digest
    end
  end

  describe "confirmation bound to the exact boundary shown" do
    test "first start requires it, an unchanged boundary reuses it, a change invalidates it",
         ctx do
      disclosure = ProcessingDisclosure.describe(@local)

      refute ProcessingDisclosure.confirmed?(ctx.project.id, ctx.owner, disclosure)

      # A digest that no longer matches what is in force cannot be confirmed.
      assert {:error, :boundary_changed} =
               ProcessingDisclosure.confirm(ctx.project.id, ctx.owner, "stale", disclosure)

      assert {:ok, confirmation} =
               ProcessingDisclosure.confirm(
                 ctx.project.id,
                 ctx.owner,
                 disclosure.digest,
                 disclosure
               )

      assert confirmation.disclosure_digest == disclosure.digest
      assert confirmation.confirmed_at
      assert ProcessingDisclosure.confirmed?(ctx.project.id, ctx.owner, disclosure)

      # The person did not agree to a boundary that did not exist yet.
      changed = ProcessingDisclosure.describe(@remote)
      refute ProcessingDisclosure.confirmed?(ctx.project.id, ctx.owner, changed)

      assert {:ok, _reconfirmed} =
               ProcessingDisclosure.confirm(ctx.project.id, ctx.owner, changed.digest, changed)

      assert ProcessingDisclosure.confirmed?(ctx.project.id, ctx.owner, changed)
    end

    test "a confirmation belongs to one person and a stranger cannot record one", ctx do
      disclosure = ProcessingDisclosure.describe(@local)

      {:ok, _confirmation} =
        ProcessingDisclosure.confirm(ctx.project.id, ctx.owner, disclosure.digest, disclosure)

      # The owner's agreement is not the participant's.
      refute ProcessingDisclosure.confirmed?(ctx.project.id, ctx.participant, disclosure)

      stranger = %{account_id: Ecto.UUID.generate(), hosted_identity_id: nil}

      assert {:error, :unauthorized} =
               ProcessingDisclosure.confirm(
                 ctx.project.id,
                 stranger,
                 disclosure.digest,
                 disclosure
               )
    end
  end
end
