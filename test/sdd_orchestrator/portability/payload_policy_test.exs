defmodule SddOrchestrator.Portability.PayloadPolicyTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Portability.{PackageSection, PayloadPolicy, ProjectPackage}
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}

  test "accepts only the exact approved field map" do
    assert PayloadPolicy.allowed_fields() == %{
             project: ~w(id name),
             repository: ~w(provider repository_id),
             specification: ~w(design id requirements tasks title)
           }

    assert :ok = PayloadPolicy.validate(package())

    extra_project =
      put_in(
        package().project.content,
        Map.put(package().project.content, "storage_mode", "hosted")
      )

    assert {:error, :forbidden_payload_field} = PayloadPolicy.validate(extra_project)

    extra_repository =
      put_in(
        package().repository.content,
        Map.put(package().repository.content, "remote_url", "https://example.test/repo")
      )

    assert {:error, :forbidden_payload_field} = PayloadPolicy.validate(extra_repository)

    [specification] = package().specifications.content

    extra_specification =
      put_in(
        package().specifications.content,
        [Map.put(specification, "attachment", "payload.bin")]
      )

    assert {:error, :forbidden_payload_field} =
             PayloadPolicy.validate(extra_specification)
  end

  test "rejects high-confidence credentials in any approved string value" do
    secrets = [
      "ghp_abcdefghijklmnopqrstuvwxyz123456",
      "sk-abcdefghijklmnopqrstuvwxyz123456",
      "AKIAABCDEFGHIJKLMNOP",
      "Bearer abcdefghijklmnopqrstuvwxyz",
      "refresh_token=do-not-export",
      "client_secret: do-not-export"
    ]

    for secret <- secrets do
      secret_package =
        update_in(package().specifications.content, fn [specification] ->
          [Map.put(specification, "design", secret)]
        end)

      assert {:error, :secret_detected} = PayloadPolicy.validate(secret_package)
    end
  end

  test "does not mistake inert command or path-looking document prose for executable input" do
    inert = "$(touch /tmp/not-executed) and document ../architecture.md"

    inert_package =
      update_in(package().specifications.content, fn [specification] ->
        [Map.put(specification, "design", inert)]
      end)

    assert :ok = PayloadPolicy.validate(inert_package)
    refute File.exists?("/tmp/not-executed")
  end

  test "new project and repository source fields stay excluded unless the allowlist changes" do
    allowed_source_atoms =
      PayloadPolicy.allowed_fields()
      |> Map.values()
      |> List.flatten()
      |> MapSet.new(&String.to_atom/1)

    project_fields = MapSet.new(Project.__schema__(:fields))
    repository_fields = MapSet.new(RepositoryConnection.__schema__(:fields))

    refute MapSet.subset?(project_fields, allowed_source_atoms)
    refute MapSet.subset?(repository_fields, allowed_source_atoms)

    forbidden_source_fields =
      ~w(
        workspace_id storage_mode lifecycle_state onboarding_attempt_id
        owner full_name html_url visibility private organization installation_id
        last_validated_at state
      )a

    for field <- forbidden_source_fields do
      refute MapSet.member?(allowed_source_atoms, field)
    end
  end

  defp package do
    project = section(:project, %{"id" => Ecto.UUID.generate(), "name" => "Payments"})

    repository =
      section(:repository, %{"provider" => "github", "repository_id" => "123"})

    specifications =
      section(:specifications, [
        %{
          "id" => Ecto.UUID.generate(),
          "title" => "Refunds",
          "requirements" => "requirements",
          "design" => "design",
          "tasks" => "tasks"
        }
      ])

    {:ok, package} = ProjectPackage.new(project, repository, specifications)
    package
  end

  defp section(name, content) do
    {:ok, section} = PackageSection.new(name, 1, content)
    section
  end
end
