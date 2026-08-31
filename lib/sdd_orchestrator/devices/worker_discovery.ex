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
      (not attached to the control plane, never seen, or its last heartbeat is
      stale), so its projects stay visible with an unavailable connection state
      instead of appearing deleted.
    * `:detected` — a compatible worker is attached right now and can open the
      folder picker and validate a repository.

  Supports the current macOS major and the immediately previous one over worker
  protocol version 1. That window is *computed* from `@macos_releases`, a
  maintained table of macOS majors and their public GA dates, against the
  current instant: the current major is the highest tabulated major whose
  release date has passed, and the window is that major plus the tabulated one
  immediately before it. A worker reporting exactly one major above the highest
  tabulated entry is tolerated as compatible, so a genuinely released major is
  never refused merely because its row has not been added yet; two or more above,
  or anything below the computed floor, stays incompatible.

  Reachability has one definition, `Devices.worker_available?/1`: the worker is
  attached to the control plane right now. A list that offers a worker and the
  action that then uses it read that same answer, so neither can contradict the
  other. `LocalWorker.last_seen_at` stays for display and for the staleness rule
  below: a worker whose last heartbeat is old is reported `:unavailable` even
  when an attachment is present, because the two disagree about the same worker.
  """

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.LocalWorker

  @supported_os_family "macos"
  @supported_protocol_versions ~w(1)

  # Maintained macOS major/GA-release-date reference table, ascending. Apple's
  # numbering is not contiguous (15 was followed by 26), so "the previous major"
  # means the previous tabulated row, never `major - 1`. Adding one row per Apple
  # release is the only upkeep this policy needs.
  @macos_releases [
    {13, ~D[2022-10-24]},
    {14, ~D[2023-09-26]},
    {15, ~D[2024-09-16]},
    {26, ~D[2025-09-15]}
  ]

  @highest_tabulated_major @macos_releases |> List.last() |> elem(0)

  # A compatible worker that has not reported within this window is treated as
  # not currently reachable, so onboarding shows an unavailable state rather than
  # acting on a stale heartbeat.
  @staleness_seconds 90

  @type status :: :missing | :incompatible | :unavailable | :detected

  @doc """
  The supported worker compatibility policy for this slice.

  Pass `now:` to evaluate the computed macOS window against a fixed instant
  (used in tests).
  """
  @spec compatibility_policy(keyword()) :: %{
          os_family: String.t(),
          os_majors: [String.t()],
          protocol_versions: [String.t()]
        }
  def compatibility_policy(opts \\ []) do
    %{
      os_family: @supported_os_family,
      os_majors: supported_os_majors(today(opts)),
      protocol_versions: @supported_protocol_versions
    }
  end

  @doc "The number of seconds after which a compatible worker's heartbeat is stale."
  @spec staleness_seconds() :: pos_integer()
  def staleness_seconds, do: @staleness_seconds

  @doc """
  Whether one worker satisfies the supported compatibility policy.

  Pass `now:` to evaluate the computed macOS window against a fixed instant.
  """
  @spec compatible?(LocalWorker.t(), keyword()) :: boolean()
  def compatible?(worker, opts \\ [])

  def compatible?(
        %LocalWorker{os_family: family, os_major: major, protocol_version: protocol},
        opts
      ) do
    family == @supported_os_family and protocol in @supported_protocol_versions and
      supported_major?(major, today(opts))
  end

  @doc """
  Classifies the discovery status for a device workspace's active workers.

  Pass `now:` to evaluate reachability and the computed macOS window against a
  fixed instant (used in tests).
  """
  @spec status([LocalWorker.t()], keyword()) :: status()
  def status(workers, opts \\ []) when is_list(workers) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    compatible = Enum.filter(workers, &compatible?(&1, opts))

    cond do
      workers == [] -> :missing
      compatible == [] -> :incompatible
      Enum.any?(compatible, &reachable?(&1, now)) -> :detected
      true -> :unavailable
    end
  end

  # The window: the highest tabulated major already released on `date`, plus the
  # tabulated major immediately before it. Before the earliest tabulated release
  # the window is that earliest major alone.
  defp supported_os_majors(date) do
    released = Enum.filter(@macos_releases, fn {_major, ga} -> Date.compare(date, ga) != :lt end)

    case released do
      [] -> @macos_releases |> Enum.take(1) |> majors()
      _ -> released |> Enum.take(-2) |> majors()
    end
  end

  defp majors(rows), do: Enum.map(rows, fn {major, _ga} -> Integer.to_string(major) end)

  defp supported_major?(major, date) when is_binary(major) do
    major in supported_os_majors(date) or forward_tolerated?(major)
  end

  defp supported_major?(_major, _date), do: false

  # One major of forward tolerance for a released major not yet tabulated here,
  # so a genuinely current worker is never refused by a missing table row alone.
  defp forward_tolerated?(major) do
    case Integer.parse(major) do
      {value, ""} -> value == @highest_tabulated_major + 1
      _ -> false
    end
  end

  defp today(opts) do
    case Keyword.get(opts, :now) do
      nil -> Date.utc_today()
      %DateTime{} = instant -> DateTime.to_date(instant)
      %Date{} = date -> date
    end
  end

  # Reachable means attached right now, which is the one availability definition
  # every list and every action reads. The heartbeat is kept as a second
  # condition: an attachment beside an ancient `last_seen_at` is a contradiction
  # about one worker, and the safe reading of a contradiction is unavailable.
  defp reachable?(%LocalWorker{} = worker, now) do
    fresh_heartbeat?(worker, now) and Devices.worker_available?(worker)
  end

  defp fresh_heartbeat?(%LocalWorker{last_seen_at: nil}, _now), do: false

  defp fresh_heartbeat?(%LocalWorker{last_seen_at: last_seen}, now) do
    DateTime.diff(now, last_seen, :second) <= @staleness_seconds
  end
end
