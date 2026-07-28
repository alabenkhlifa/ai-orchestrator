defmodule SddOrchestrator.Portability.RestorePackage do
  @moduledoc false

  import Bitwise

  alias SddOrchestrator.Portability.{PackageSection, ProjectPackage, RestoreDecision}
  alias SddOrchestrator.Specifications.SpecificationRestore

  def decision_matches(
        %RestoreDecision{
          project_id: project_id,
          repository_provider: provider,
          repository_id: repository_id
        },
        %ProjectPackage{
          project: %PackageSection{content: %{"id" => packaged_project_id}},
          repository: %PackageSection{
            content: %{"provider" => packaged_provider, "repository_id" => packaged_repository_id}
          }
        }
      ) do
    with {:ok, packaged_id} <- Ecto.UUID.cast(packaged_project_id),
         true <- project_id == packaged_id,
         true <- provider == packaged_provider,
         true <- repository_id == packaged_repository_id do
      :ok
    else
      _reason -> {:error, :invalid_restore}
    end
  end

  def decision_matches(_decision, _package), do: {:error, :invalid_restore}

  def specification_values(%ProjectPackage{
        project: %PackageSection{content: %{"id" => project_id}},
        specifications: %PackageSection{content: specifications}
      })
      when is_list(specifications) do
    values =
      Enum.map(specifications, fn specification ->
        %{
          id: specification["id"],
          title: specification["title"],
          revision_id: revision_id(project_id, specification["id"]),
          requirements: specification["requirements"],
          design: specification["design"],
          tasks: specification["tasks"]
        }
      end)

    case SpecificationRestore.normalize(values) do
      {:ok, _entries} -> {:ok, values}
      {:error, reason} -> {:error, reason}
    end
  end

  def specification_values(_package), do: {:error, :invalid_restore}

  defp revision_id(project_id, specification_id) do
    digest =
      :crypto.hash(
        :sha256,
        "sdd-orchestrator:restore-revision:v1:" <> project_id <> ":" <> specification_id
      )

    <<time_low::32, time_mid::16, time_high::16, clock_seq::16, node::48, _rest::binary>> =
      digest

    versioned_time_high = bor(band(time_high, 0x0FFF), 0x5000)
    variant_clock_seq = bor(band(clock_seq, 0x3FFF), 0x8000)

    {:ok, uuid} =
      Ecto.UUID.load(
        <<time_low::32, time_mid::16, versioned_time_high::16, variant_clock_seq::16, node::48>>
      )

    uuid
  end
end
