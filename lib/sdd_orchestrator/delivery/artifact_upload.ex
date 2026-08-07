defmodule SddOrchestrator.Delivery.ArtifactUpload do
  @moduledoc """
  The only way worker-captured bytes become a stored artifact.

  A meaningful screenshot is far larger than the protocol's bounded event
  payload, so evidence bytes cannot ride inside a normalized event. They arrive
  instead through the worker's own authenticated upload, and what the event
  later carries is the digest this module already verified.

  Nothing here trusts the worker's description of what it sent. The credential
  names the project, so a `project_id` in the request cannot widen it; the run
  is read through that project's own authority, the attempt must be the run's
  current one, and the fence must be that attempt's — the same three proofs
  `EventIngestion` applies to every event, for the same reason: a superseded
  worker that never noticed it was replaced must be able to keep talking without
  being able to write anything.

  A device-authoritative project is refused outright rather than stored. Its
  worker owns its artifacts and writes them locally; accepting an upload would
  create exactly the hosted copy `specs/05` forbids, so the refusal is a typed
  decision here and not an accident of the store being unreachable.

  Refusals that would otherwise answer "does this exist?" are deliberately one
  answer at the boundary. This module still names them precisely, because the
  transport that collapses them has to know which ones to collapse.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.{ArtifactStore, DeliveryStore, RunAttempt}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceProject
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type claims :: %{project_id: String.t(), worker_id: String.t()}

  @type accepted :: %{
          ref: ArtifactStore.ref(),
          digest: String.t(),
          stored: boolean()
        }

  @type error ::
          :unauthorized_worker
          | :unknown_project
          | :device_authoritative
          | :unknown_run
          | :no_current_attempt
          | :stale_fence
          | :invalid_request
          | ArtifactStore.error()

  # Every reason that would disclose whether a project, run, attempt, or stored
  # artifact exists. The transport answers all of them identically, so an
  # unauthorized worker and an unknown run are the same event to a caller.
  @undisclosed ~w(
    unauthorized_worker
    unknown_project
    device_authoritative
    unknown_run
    no_current_attempt
    stale_fence
  )a

  @doc "The refusals that must not be told apart from outside."
  @spec undisclosed() :: [error()]
  def undisclosed, do: @undisclosed

  @doc "Reports whether one refusal would disclose the existence of project state."
  @spec undisclosed?(term()) :: boolean()
  def undisclosed?(reason), do: reason in @undisclosed

  @doc """
  Stores one worker-uploaded artifact for the project its credential names.

  `params` carries the declared metadata with string keys, exactly as it arrives
  on the wire; `content` is the raw body. Success reports whether the bytes were
  written now or were already held, because a repeat upload of the same digest
  is answered rather than duplicated.
  """
  @spec accept(claims(), map(), binary()) :: {:ok, accepted()} | {:error, error()}
  def accept(%{project_id: project_id}, params, content) when is_binary(content) do
    with {:ok, request} <- request(params),
         {:ok, authority} <- uploadable_authority(project_id),
         {:ok, run} <- run(authority, project_id, request),
         {:ok, attempt} <- current_attempt(authority, project_id, run),
         :ok <- current_fence?(attempt, request) do
      store(authority, project_id, request, content)
    end
  end

  def accept(_claims, _params, _content), do: {:error, :unauthorized_worker}

  # The declared metadata is read into a known shape before anything is looked
  # up, so a malformed request is refused rather than half-interpreted. What the
  # bytes actually are is not judged here: the store recomputes that, and it must
  # not be answered before the caller has proved it may upload at all.
  defp request(params) when is_map(params) do
    with {:ok, run_id} <- identifier(params["run_id"]),
         {:ok, fence} <- fence(params["fence"]),
         {:ok, digest} <- declared(params["digest"]),
         {:ok, content_type} <- declared(params["content_type"]),
         {:ok, redacted} <- redacted(params["redacted"]) do
      {:ok,
       %{
         run_id: run_id,
         fence: fence,
         digest: digest,
         content_type: content_type,
         redacted: redacted
       }}
    end
  end

  defp request(_params), do: {:error, :invalid_request}

  defp identifier(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  defp identifier(_value), do: {:error, :invalid_request}

  defp declared(value) when is_binary(value), do: {:ok, value}
  defp declared(_value), do: {:error, :invalid_request}

  defp fence(value) when is_binary(value) do
    case Integer.parse(value) do
      {fence, ""} when fence > 0 -> {:ok, fence}
      _unusable -> {:error, :invalid_request}
    end
  end

  defp fence(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp fence(_value), do: {:error, :invalid_request}

  # Redaction is a privacy claim about the bytes, so anything that is not plainly
  # true or false is refused rather than quietly read as "not redacted".
  defp redacted(nil), do: {:ok, false}
  defp redacted(value) when is_boolean(value), do: {:ok, value}
  defp redacted("true"), do: {:ok, true}
  defp redacted("false"), do: {:ok, false}
  defp redacted(_value), do: {:error, :invalid_redaction}

  # Only a hosted project can receive an upload at all. A device-authoritative
  # project is named as such rather than lumped in with "unknown", because
  # storing its bytes here is the one outcome that would break `specs/05`.
  defp uploadable_authority(project_id) do
    case authority(project_id) do
      {:ok, %PersonalWorkspace{} = authority} -> {:ok, authority}
      {:ok, %DeviceWorkspace{}} -> {:error, :device_authoritative}
      :error -> {:error, :unknown_project}
    end
  end

  defp authority(project_id) do
    case hosted_authority(project_id) do
      {:ok, authority} -> {:ok, authority}
      :error -> device_authority(project_id)
    end
  end

  defp hosted_authority(project_id) do
    Project
    |> where([p], p.id == ^project_id and p.storage_mode == "hosted")
    |> join(:inner, [p], w in PersonalWorkspace, on: w.id == p.workspace_id)
    |> select([_project, workspace], workspace)
    |> Repo.one()
    |> case do
      %PersonalWorkspace{} = authority -> {:ok, authority}
      nil -> :error
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  # The device store lives on the worker's own machine, so a control-plane node
  # may not be able to reach it at all. That answers exactly like a project the
  # device does not have: an upload is refused either way, and the one thing
  # that must never happen — a device project's bytes landing here — cannot.
  defp device_authority(project_id) do
    case Devices.get_project(project_id) do
      {:ok, %DeviceProject{workspace_id: workspace_id}} ->
        {:ok, %DeviceWorkspace{id: workspace_id}}

      {:error, :not_found} ->
        :error
    end
  catch
    :exit, _unreachable -> :error
  end

  defp run(authority, project_id, %{run_id: run_id}) do
    case DeliveryStore.fetch_run(authority, project_id, run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, :unknown_run}
    end
  end

  defp current_attempt(authority, project_id, run) do
    case DeliveryStore.current_attempt(authority, project_id, run.id) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, :no_current_attempt}
    end
  end

  defp current_fence?(%RunAttempt{fence_token: fence}, %{fence: fence}), do: :ok
  defp current_fence?(_attempt, _request), do: {:error, :stale_fence}

  # The store recomputes the digest, scans for credential material, and enforces
  # the shared type and size limits, so the declared description is proved
  # against the bytes rather than believed.
  defp store(authority, project_id, request, content) do
    attrs = %{
      content: content,
      content_type: request.content_type,
      digest: request.digest,
      redacted: request.redacted
    }

    with {:ok, verified} <- ArtifactStore.validate(attrs),
         held? = held?(authority, project_id, verified.digest),
         {:ok, ref} <- ArtifactStore.put(authority, project_id, attrs) do
      {:ok, %{ref: ref, digest: verified.digest, stored: not held?}}
    end
  end

  # Uploads are idempotent by digest, so what the project already holds is read
  # before the store is asked again. That is the only way the answer can say
  # "already yours" instead of reporting a write that never happened.
  defp held?(authority, project_id, digest) do
    match?(
      {:ok, _artifact},
      ArtifactStore.stat(authority, project_id, ArtifactStore.ref_for(digest))
    )
  end
end
