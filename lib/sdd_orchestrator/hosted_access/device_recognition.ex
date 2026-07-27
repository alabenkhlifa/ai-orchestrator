defmodule SddOrchestrator.HostedAccess.DeviceRecognition do
  @moduledoc """
  Reduces a browser user-agent to coarse recognition fields.

  The full header is used only in memory for this conversion and is never
  persisted. The result intentionally avoids versions, IP addresses, and
  fingerprinting attributes.
  """

  @spec from_user_agent(String.t() | nil) :: %{
          user_agent_family: String.t(),
          os_family: String.t()
        }
  def from_user_agent(user_agent) when is_binary(user_agent) do
    %{
      user_agent_family: browser_family(user_agent),
      os_family: os_family(user_agent)
    }
  end

  def from_user_agent(_user_agent) do
    %{user_agent_family: "Unknown browser", os_family: "Unknown OS"}
  end

  defp browser_family(user_agent) do
    cond do
      String.contains?(user_agent, ["Edg/", "Edge/"]) -> "Edge"
      String.contains?(user_agent, ["OPR/", "Opera/"]) -> "Opera"
      String.contains?(user_agent, "Firefox/") -> "Firefox"
      String.contains?(user_agent, ["CriOS/", "Chrome/"]) -> "Chrome"
      String.contains?(user_agent, "Safari/") -> "Safari"
      true -> "Other browser"
    end
  end

  defp os_family(user_agent) do
    cond do
      String.contains?(user_agent, ["iPhone", "iPad", "iPod"]) -> "iOS"
      String.contains?(user_agent, "Android") -> "Android"
      String.contains?(user_agent, ["Windows NT", "Windows Phone"]) -> "Windows"
      String.contains?(user_agent, ["Macintosh", "Mac OS X"]) -> "macOS"
      String.contains?(user_agent, "Linux") -> "Linux"
      true -> "Other OS"
    end
  end
end
