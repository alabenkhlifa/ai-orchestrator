defmodule SddOrchestrator.Portability.PackageSection do
  @moduledoc """
  One versioned, allowlisted logical section in a project backup payload.

  Section content is data only. The codec never treats document values as
  paths, filenames, templates, or executable input.
  """

  @type name :: :project | :repository | :specifications
  @type t :: %__MODULE__{
          name: name(),
          version: pos_integer(),
          content: map() | [map()]
        }

  @enforce_keys [:name, :version, :content]
  defstruct [:name, :version, :content]

  @names [:project, :repository, :specifications]

  @spec new(name(), pos_integer(), map() | [map()]) :: {:ok, t()} | {:error, atom()}
  def new(name, version, content)
      when name in @names and is_integer(version) and version > 0 and
             (is_map(content) or is_list(content)) do
    {:ok, %__MODULE__{name: name, version: version, content: content}}
  end

  def new(name, _version, _content) when name not in @names, do: {:error, :invalid_section_name}

  def new(_name, version, _content) when not is_integer(version) or version <= 0,
    do: {:error, :invalid_section_version}

  def new(_name, _version, _content), do: {:error, :invalid_section_content}
end
