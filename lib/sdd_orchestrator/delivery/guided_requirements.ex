defmodule SddOrchestrator.Delivery.GuidedRequirements do
  @moduledoc """
  The shape of the requirements document a person fills in for one feature.

  The document is Markdown with one second-level heading per guided part. The
  headings are derived from `Readiness.guided_structure/0` at runtime rather
  than copied here, so the parts a person writes and the parts readiness judges
  cannot drift apart.

  Rendering and parsing are the only way the product reads or writes that
  shape, and they round-trip: parsing a rendered document answers the same four
  bodies. Anything else in the document is left where it is. A run writes its
  own sections into the same requirements, and reading the form must not
  quietly delete them.
  """

  alias SddOrchestrator.Delivery.Readiness

  @type parts :: %{optional(String.t()) => String.t()}

  @doc "The guided parts, in the order the document and the form present them."
  @spec structure() :: [%{key: String.t(), label: String.t(), hint: String.t()}]
  def structure, do: Readiness.guided_structure()

  @doc "The keys `parse/1` answers and `render/1` reads."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(structure(), & &1.key)

  @doc """
  The document a feature starts with: every heading present, nothing under any
  of them.
  """
  @spec empty() :: String.t()
  def empty, do: render(%{})

  @doc """
  Renders one body per guided part as the feature's requirements document.

  A missing or blank part still gets its heading, because the reader has to see
  which part is empty. Surrounding whitespace is dropped so two saves of the
  same words produce the same document.
  """
  @spec render(map()) :: String.t()
  def render(parts) when is_map(parts) do
    structure()
    |> Enum.map_join("\n\n", &section(&1, body(parts, &1.key)))
    |> Kernel.<>("\n")
  end

  @doc """
  Reads the four guided bodies back out of a requirements document.

  A heading that is present with nothing under it answers an empty string, and
  so does a heading that is absent. Sections the four do not name are ignored
  rather than reported, so a document that carries more than the guided parts
  still opens in the form.
  """
  @spec parse(String.t()) :: parts()
  def parse(document) when is_binary(document) do
    sections = sections(document)

    Map.new(structure(), fn part -> {part.key, Map.get(sections, part.label, "")} end)
  end

  def parse(_document), do: parse("")

  defp section(part, ""), do: "## " <> part.label
  defp section(part, body), do: "## " <> part.label <> "\n\n" <> body

  defp body(parts, key) do
    case Map.get(parts, key) do
      value when is_binary(value) -> String.trim(value)
      _absent -> ""
    end
  end

  # One pass over the lines, closing the open section whenever a heading starts
  # the next one. The first occurrence of a heading wins, so a document that
  # repeats one reads the same way twice.
  defp sections(document) do
    document
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce({nil, [], %{}}, &collect/2)
    |> close()
  end

  defp collect(line, {label, lines, sections}) do
    case heading(line) do
      {:ok, next} -> {next, [], close({label, lines, sections})}
      :none -> {label, [line | lines], sections}
    end
  end

  defp close({nil, _lines, sections}), do: sections

  defp close({label, lines, sections}) do
    body =
      lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    Map.put_new(sections, label, body)
  end

  defp heading("## " <> label), do: {:ok, String.trim(label)}
  defp heading(_line), do: :none
end
