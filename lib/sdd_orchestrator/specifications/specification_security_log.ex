defmodule SddOrchestrator.Specifications.SpecificationSecurityLog do
  @moduledoc """
  Fixed, content-free security outcomes for the specification boundary.

  Events never contain project, specification, revision, actor, title, path, or
  document values. Deployment logging infrastructure applies the approved
  30-day expiry.
  """

  require Logger

  @events [:append_revision, :create, :current_snapshot, :get_current, :prepare_restore]

  @spec audit(term(), atom()) :: term()
  def audit({:error, reason} = result, event) when event in @events do
    Logger.warning("[specification_security] event=#{event} outcome=#{outcome(reason)}")

    result
  end

  def audit(result, event) when event in @events, do: result

  defp outcome(%Ecto.Changeset{}), do: "validation_rejected"
  defp outcome(:not_found), do: "denied_or_missing"
  defp outcome(:stale_revision), do: "stale_write_rejected"

  defp outcome(reason)
       when reason in [
              :revision_conflict,
              :restore_conflict,
              :specification_conflict
            ],
       do: "identity_conflict"

  defp outcome(reason)
       when reason in [
              :document_too_large,
              :invalid_actor_ref,
              :invalid_document,
              :invalid_document_set,
              :invalid_idempotency_key,
              :invalid_restore,
              :invalid_revision,
              :invalid_specification,
              :invalid_title,
              :snapshot_too_large,
              :specification_limit_exceeded
            ],
       do: "validation_rejected"

  defp outcome(_reason), do: "operation_failed"
end
