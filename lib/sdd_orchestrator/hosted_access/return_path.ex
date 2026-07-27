defmodule SddOrchestrator.HostedAccess.ReturnPath do
  @moduledoc "Restricts hosted-access handoffs to application-local paths."

  @default "/hosted/access/sessions"

  @spec sanitize(term()) :: String.t()
  def sanitize("/" <> _rest = path) do
    uri = URI.parse(path)

    if is_nil(uri.host) and is_nil(uri.scheme) and not String.starts_with?(path, "//") do
      path
    else
      @default
    end
  end

  def sanitize(_path), do: @default
end
