defmodule SddOrchestrator.Specifications.SpecificationSnapshot do
  @moduledoc """
  Transient, allowlisted current-specification view for one authorized project.

  It contains no project path, storage mode, actor reference, digest, prior
  revision, credential, repository value, or persistence association.
  """

  alias SddOrchestrator.Specifications.SpecificationLimits

  defmodule Entry do
    @moduledoc false

    @enforce_keys [
      :id,
      :title,
      :revision_id,
      :requirements,
      :design,
      :tasks
    ]
    defstruct [:id, :title, :revision_id, :requirements, :design, :tasks]

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            title: String.t(),
            revision_id: Ecto.UUID.t(),
            requirements: String.t(),
            design: String.t(),
            tasks: String.t()
          }
  end

  @enforce_keys [:specifications]
  defstruct [:specifications]

  @type t :: %__MODULE__{specifications: [Entry.t()]}

  @spec new([SddOrchestrator.SpecificationStore.current()]) ::
          {:ok, t()} | {:error, atom()}
  def new(currents) when is_list(currents) do
    entries =
      currents
      |> Enum.map(&entry/1)
      |> Enum.sort_by(& &1.id)

    cond do
      length(entries) > SpecificationLimits.get(:max_specifications_per_project) ->
        {:error, :specification_limit_exceeded}

      snapshot_bytes(entries) > SpecificationLimits.get(:max_snapshot_bytes) ->
        {:error, :snapshot_too_large}

      true ->
        {:ok, %__MODULE__{specifications: entries}}
    end
  end

  defp entry(%{specification: specification, revision: revision}) do
    %Entry{
      id: specification.id,
      title: specification.title,
      revision_id: revision.id,
      requirements: revision.requirements_document,
      design: revision.design_document,
      tasks: revision.tasks_document
    }
  end

  defp snapshot_bytes(entries) do
    Enum.reduce(entries, 0, fn entry, total ->
      total +
        Enum.reduce(Map.from_struct(entry), 0, fn {_key, value}, entry_total ->
          entry_total + byte_size(value)
        end)
    end)
  end
end
