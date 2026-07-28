defmodule SddOrchestrator.SpecificationFixtures do
  @moduledoc false

  alias SddOrchestrator.SpecificationStore

  def documents(overrides \\ %{}) do
    Map.merge(
      %{
        requirements: "# Requirements\n\nStore one complete specification.",
        design: "# Design\n\nUse immutable complete revisions.",
        tasks: "# Tasks\n\n- [ ] Implement the store"
      },
      Map.new(overrides)
    )
  end

  def specification_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        revision_id: Ecto.UUID.generate(),
        title: "Specification storage",
        documents: documents()
      },
      Map.new(overrides)
    )
  end

  def hosted_specification(workspace, project, overrides \\ %{}) do
    attrs = specification_attrs(overrides)
    {:ok, current} = SpecificationStore.create(workspace, project.id, attrs, actor_ref: "owner")
    current
  end
end
