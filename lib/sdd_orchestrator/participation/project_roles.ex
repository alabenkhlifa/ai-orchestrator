defmodule SddOrchestrator.Participation.ProjectRoles do
  @moduledoc """
  Detects whether an address already holds a role in one project.

  The check reads only identities that are already authorized members of that
  project — the immutable owner and its active participants — so it can never
  become a lookup for an unrelated account or a searchable directory. Addresses
  are compared as runtime-keyed digests in constant time, and the result names
  only a project role the owner is already entitled to see.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{ExternalIdentity, HostedIdentity}
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{EmailDigest, ProjectParticipant}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type role :: :owner | :participant

  @doc """
  Returns the project role already held by the digested address, or `nil`.

  The same member digests are collected whether or not a match exists, so an
  unknown address and a member address perform the same work.
  """
  @spec existing_role(Project.t(), binary()) :: role() | nil
  def existing_role(%Project{id: id} = project, email_digest)
      when is_binary(id) and is_binary(email_digest) do
    owner_match? = matches?(owner_digests(project), email_digest)
    participant_match? = matches?(participant_digests(project), email_digest)

    cond do
      owner_match? -> :owner
      participant_match? -> :participant
      true -> nil
    end
  end

  def existing_role(_project, _email_digest), do: nil

  defp owner_digests(project) do
    case Participation.owner(project) do
      {:ok, %{account_id: account_id}} -> digests_for_accounts([account_id])
      {:error, _reason} -> []
    end
  end

  defp participant_digests(project) do
    HostedIdentity
    |> join(:inner, [h], p in ProjectParticipant, on: p.hosted_identity_id == h.id)
    |> join(:inner, [h, _p], e in ExternalIdentity, on: e.hosted_identity_id == h.id)
    |> where(
      [_h, p, e],
      p.project_id == ^project.id and p.state == "active" and e.provider == "email"
    )
    |> select([_h, _p, e], e.subject_key)
    |> Repo.all()
    |> Enum.map(&EmailDigest.from_subject_key/1)
  end

  defp digests_for_accounts(account_ids) do
    ExternalIdentity
    |> join(:inner, [e], h in HostedIdentity, on: e.hosted_identity_id == h.id)
    |> where([e, h], h.account_id in ^account_ids and e.provider == "email")
    |> select([e, _h], e.subject_key)
    |> Repo.all()
    |> Enum.map(&EmailDigest.from_subject_key/1)
  end

  # Every candidate is compared, and each comparison is constant time, so the
  # answer does not leak through how quickly it was produced.
  defp matches?(candidates, email_digest) do
    Enum.reduce(candidates, false, fn candidate, matched? ->
      :crypto.hash_equals(candidate, email_digest) or matched?
    end)
  end
end
