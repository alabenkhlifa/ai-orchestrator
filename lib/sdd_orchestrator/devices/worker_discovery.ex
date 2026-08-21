defmodule SddOrchestrator.Devices.WorkerDiscovery do
  @moduledoc """
  The compatibility and reachability policy for local worker discovery.

  Given the active workers paired to a device workspace, `status/2` classifies
  the onboarding-relevant state without contacting a worker:

    * `:missing` — no worker is paired, so the user needs graphical installation
      and pairing guidance.
    * `:incompatible` — a worker is paired but none satisfies the supported
      macOS/protocol policy, so the user needs to update or reinstall.
    * `:unavailable` — a compatible worker is paired but not currently reachable
      (never seen, or its last heartbeat is stale), so its projects stay visible
      with an unavailable connection state instead of appearing deleted.
    * `:detected` — a compatible worker has reported in recently and can open the
      folder picker and validate a repository.

  Supports the current macOS major and the immediately previous one (currently
  25 and 26) over worker protocol version 1 — a sliding window that must be
  updated here as new macOS majors ship. Reachability is modeled through
  `LocalWorker.last_seen_at`; the real native worker updates it over its
  outbound transport (release-gated).
  """

  alias SddOrchestrator.Devices.LocalWorker

  @supported_os_family "macos"
  @supported_os_majors ~w(25 26)
  @supported_protocol_versions ~w(1)

  # A compatible worker that has not reported within this window is treated as
  # not currently reachable, so onboarding shows an unavailable state rather than
  # acting on a stale heartbeat.
  @staleness_seconds 90

  @type status :: :missing | :incompatible | :unavailable | :detected

  @doc "The supported worker compatibility policy for this slice."
  @spec compatibility_policy() :: %{
          os_family: String.t(),
          os_majors: [String.t()],
          protocol_versions: [String.t()]
        }
  def compatibility_policy do
    %{
      os_family: @supported_os_family,
      os_majors: @supported_os_majors,
      protocol_versions: @supported_protocol_versions
    }
  end

  @doc "The number of seconds after which a compatible worker's heartbeat is stale."
  @spec staleness_seconds() :: pos_integer()
  def staleness_seconds, do: @staleness_seconds

  @doc "Whether one worker satisfies the supported compatibility policy."
  @spec compatible?(LocalWorker.t()) :: boolean()
  def compatible?(%LocalWorker{os_family: family, os_major: major, protocol_version: protocol}) do
    family == @supported_os_family and major in @supported_os_majors and
      protocol in @supported_protocol_versions
  end

  @doc """
  Classifies the discovery status for a device workspace's active workers.

  Pass `now:` to evaluate reachability against a fixed instant (used in tests).
  """
  @spec status([LocalWorker.t()], keyword()) :: status()
  def status(workers, opts \\ []) when is_list(workers) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    compatible = Enum.filter(workers, &compatible?/1)

    cond do
      workers == [] -> :missing
      compatible == [] -> :incompatible
      Enum.any?(compatible, &reachable?(&1, now)) -> :detected
      true -> :unavailable
    end
  end

  defp reachable?(%LocalWorker{last_seen_at: nil}, _now), do: false

  defp reachable?(%LocalWorker{last_seen_at: last_seen}, now) do
    DateTime.diff(now, last_seen, :second) <= @staleness_seconds
  end
end
