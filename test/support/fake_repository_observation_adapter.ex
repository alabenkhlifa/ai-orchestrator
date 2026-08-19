defmodule SddOrchestrator.ProjectAssistant.FakeRepositoryObservationAdapter do
  @moduledoc """
  Deterministic `RepositoryObservationAdapter` test double for specs/12
  Tasks 4 and 5. No worker access, no network.

  Scenarios are keyed off `request.repository_ref`, mirroring
  `SddOrchestrator.GitHubIntegration.FakeProvider`'s login-prefix convention:

    * `"clean"` — a stable, non-dirty tree with a commit.
    * `"dirty"` — a stable tree with uncommitted changes.
    * `"empty"` — no branch and no commit, a root `tree/1` listing with zero
      entries, mirroring `RepositoryInitialization.Eligibility`'s
      `:empty_directory` classification (no `.git` at all).
    * `"unborn"` — a `.git` directory with zero commits (`commit: nil`) and
      a root `tree/1` listing with zero entries, mirroring `Eligibility`'s
      `:unborn_repository` classification.
    * `"unstable"` — relevant working-tree state changes between the scan's
      start and its completion (before/after digests differ).
    * `"generated-heavy"` — `tree/1` and `search/1` results mix ordinary
      source paths with `node_modules/` and `_build/` paths, so a caller can
      prove configured exclusions are applied.
    * `"secret-bearing"` — `tree/1` and `search/1` results mix ordinary
      source paths with `.env` and `secrets/credentials.yml`, so a caller
      can prove configured sensitive-path exclusions are applied.
    * `"non-sdd"` — `search/1` returns zero matches for any query (no
      `specs/`/`.agents/` content), never an error — AC-13's "absence
      reported directly."
    * `"large"` — `tree/1` returns 500 entries and `search/1` returns 300
      matches, each already reporting `truncated: true`; `lines/1` returns
      content larger than any default byte budget, so a caller can prove its
      own truncation on top of whatever the adapter reports.
    * `"deep"` — a three-level directory tree (`.` → `src` → `src/nested`)
      for progressive multi-call discovery proof.
    * `"fails:" <> reason` — every callback fails with `{:error, reason}`,
      independent of worker-availability denial.
    * any other value — the same as `"clean"`, so a caller that only cares
      about authorization outcomes need not pick a scenario.
  """
  @behaviour SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter

  @impl true
  def observe(%{repository_ref: "fails:" <> reason}), do: {:error, String.to_atom(reason)}

  def observe(%{repository_ref: "dirty"} = request), do: {:ok, result(request, dirty: true)}

  def observe(%{repository_ref: "empty"} = request),
    do: {:ok, result(request, commit: nil, branch: nil)}

  def observe(%{repository_ref: "unborn"} = request),
    do: {:ok, result(request, commit: nil, branch: "main")}

  def observe(%{repository_ref: "unstable"} = request),
    do: {:ok, result(request, after_digest: "digest-after-changed")}

  def observe(request), do: {:ok, result(request, [])}

  @impl true
  def tree(%{repository_ref: "fails:" <> reason}), do: {:error, String.to_atom(reason)}

  def tree(%{repository_ref: ref}) when ref in ["empty", "unborn"],
    do: {:ok, %{entries: [], truncated: false}}

  def tree(%{repository_ref: "generated-heavy"}) do
    {:ok,
     %{
       entries: [
         %{path: "lib/app.ex", type: :file},
         %{path: "mix.exs", type: :file},
         %{path: "node_modules", type: :dir},
         %{path: "node_modules/left-pad/index.js", type: :file},
         %{path: "_build", type: :dir},
         %{path: "_build/dev/lib/app/ebin/app.beam", type: :file}
       ],
       truncated: false
     }}
  end

  def tree(%{repository_ref: "secret-bearing"}) do
    {:ok,
     %{
       entries: [
         %{path: "lib/app.ex", type: :file},
         %{path: ".env", type: :file},
         %{path: "secrets", type: :dir},
         %{path: "secrets/credentials.yml", type: :file}
       ],
       truncated: false
     }}
  end

  def tree(%{repository_ref: "large", path: path}) do
    entries = for n <- 1..500, do: %{path: "#{path}/file_#{n}.ex", type: :file}
    {:ok, %{entries: entries, truncated: true}}
  end

  def tree(%{repository_ref: "deep", path: "."}) do
    {:ok,
     %{entries: [%{path: "src", type: :dir}, %{path: "README.md", type: :file}], truncated: false}}
  end

  def tree(%{repository_ref: "deep", path: "src"}) do
    {:ok,
     %{
       entries: [%{path: "src/nested", type: :dir}, %{path: "src/main.ex", type: :file}],
       truncated: false
     }}
  end

  def tree(%{repository_ref: "deep", path: "src/nested"}) do
    {:ok, %{entries: [%{path: "src/nested/leaf.ex", type: :file}], truncated: false}}
  end

  def tree(_request) do
    {:ok,
     %{entries: [%{path: "README.md", type: :file}, %{path: "lib", type: :dir}], truncated: false}}
  end

  @impl true
  def search(%{repository_ref: "fails:" <> reason}), do: {:error, String.to_atom(reason)}

  def search(%{repository_ref: "non-sdd"}), do: {:ok, %{matches: [], truncated: false}}

  def search(%{repository_ref: "generated-heavy", query: query}) do
    {:ok,
     %{
       matches: [
         %{path: "lib/app.ex", line: 3, excerpt: "defmodule App do # #{query}"},
         %{path: "node_modules/left-pad/index.js", line: 1, excerpt: "module.exports.#{query}"}
       ],
       truncated: false
     }}
  end

  def search(%{repository_ref: "secret-bearing", query: query}) do
    {:ok,
     %{
       matches: [
         %{path: "lib/app.ex", line: 5, excerpt: "# uses #{query}"},
         %{path: ".env", line: 1, excerpt: "SECRET_KEY=#{query}-token"}
       ],
       truncated: false
     }}
  end

  def search(%{repository_ref: "large", query: query}) do
    matches =
      for n <- 1..300, do: %{path: "file_#{n}.ex", line: n, excerpt: "match #{n}: #{query}"}

    {:ok, %{matches: matches, truncated: true}}
  end

  def search(%{query: query}) do
    {:ok,
     %{matches: [%{path: "README.md", line: 1, excerpt: "mentions #{query}"}], truncated: false}}
  end

  @impl true
  def lines(%{repository_ref: "fails:" <> reason}), do: {:error, String.to_atom(reason)}

  def lines(%{repository_ref: "large", path: path, start_line: s, end_line: e}) do
    {:ok, %{path: path, start_line: s, end_line: e, content: String.duplicate("x", 50_000)}}
  end

  def lines(%{path: path, start_line: s, end_line: e}) do
    content = Enum.map_join(s..e, "\n", fn n -> "line #{n} of #{path}" end)
    {:ok, %{path: path, start_line: s, end_line: e, content: content, truncated: false}}
  end

  defp result(request, overrides) do
    started = ~U[2026-01-01 12:00:00Z]
    completed = DateTime.add(started, 4, :second)

    %{
      branch: "main",
      commit: "abc123def456",
      dirty: false,
      scan_started_at: started,
      scan_completed_at: completed,
      exclusions: Map.get(request, :exclusions, []),
      before_digest: "digest-stable",
      after_digest: "digest-stable"
    }
    |> Map.merge(Map.new(overrides))
  end
end
