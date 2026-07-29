defmodule SddOrchestrator.Participation.DisplayName do
  @moduledoc """
  Project-specific presentation labels for the immutable owner and participants.

  A display name is human-facing text, never a slug, identity, or email-derived
  value. The comparison key is derived with Unicode `NFKC` normalization
  followed by default case folding, so one project rejects a conflicting label
  case-insensitively while preserving the accepted spelling.
  """

  @max_bytes 80

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Trims one submitted label and returns its accepted spelling and comparison key.
  """
  @spec normalize(term()) ::
          {:ok, %{display_name: String.t(), display_name_key: String.t()}}
          | {:error, :invalid_display_name}
  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)

    if valid?(trimmed) do
      {:ok, %{display_name: trimmed, display_name_key: key(trimmed)}}
    else
      {:error, :invalid_display_name}
    end
  end

  def normalize(_value), do: {:error, :invalid_display_name}

  @doc "Derives the case-insensitive project comparison key, or `nil` when blank."
  @spec key(String.t() | nil) :: String.t() | nil
  def key(nil), do: nil

  def key(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        trimmed
        |> :unicode.characters_to_nfkc_binary()
        |> String.downcase(:default)
    end
  end

  defp valid?(trimmed) do
    trimmed != "" and byte_size(trimmed) <= @max_bytes and
      not Regex.match?(~r/\p{Cc}/u, trimmed) and not email_shaped?(trimmed)
  end

  # An owner or participant label must not be presented as, or derived from, an
  # email address.
  defp email_shaped?(value), do: Regex.match?(~r/^[^\s@]+@[^\s@]+$/u, value)
end
