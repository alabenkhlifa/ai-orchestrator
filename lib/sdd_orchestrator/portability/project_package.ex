defmodule SddOrchestrator.Portability.ProjectPackage do
  @moduledoc """
  The decrypted, versioned project-backup payload.

  The three sections are explicit fields so their logical order cannot be
  changed by map enumeration or by a caller supplying arbitrary sections.
  """

  alias SddOrchestrator.Portability.PackageSection

  @payload_schema_version 1

  @type t :: %__MODULE__{
          payload_schema_version: pos_integer(),
          project: PackageSection.t(),
          repository: PackageSection.t(),
          specifications: PackageSection.t()
        }

  @enforce_keys [:project, :repository, :specifications]
  defstruct payload_schema_version: @payload_schema_version,
            project: nil,
            repository: nil,
            specifications: nil

  @spec payload_schema_version() :: pos_integer()
  def payload_schema_version, do: @payload_schema_version

  @spec new(PackageSection.t(), PackageSection.t(), PackageSection.t()) ::
          {:ok, t()} | {:error, atom()}
  def new(
        %PackageSection{name: :project} = project,
        %PackageSection{name: :repository} = repository,
        %PackageSection{name: :specifications} = specifications
      ) do
    {:ok,
     %__MODULE__{
       project: project,
       repository: repository,
       specifications: specifications
     }}
  end

  def new(%PackageSection{}, %PackageSection{}, %PackageSection{}),
    do: {:error, :invalid_section_order}

  def new(_project, _repository, _specifications), do: {:error, :invalid_sections}

  @spec sections(t()) :: [PackageSection.t()]
  def sections(%__MODULE__{} = package) do
    [package.project, package.repository, package.specifications]
  end
end
