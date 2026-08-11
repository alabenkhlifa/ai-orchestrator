defmodule SddOrchestratorWeb.RepositoryKitsLive do
  @moduledoc """
  Global, read-only inspection of the immutable SDD kit package catalog.

  The catalog is not project-scoped, so this view needs no project id and no
  authorization beyond the authenticated-session requirement its route
  already enforces. Task 1 owns catalog storage and inspection only: there is
  no application, diffing, or git logic here, so this view carries no form,
  edit, or delete control anywhere — it is read-only by construction.
  """

  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.RepositoryKits

  @impl true
  def mount(_params, _session, socket) do
    packages = RepositoryKits.list_packages()

    {:ok,
     socket
     |> assign(:page_title, "Repository SDD Kits")
     |> assign(:packages, packages)
     |> assign(:selected_id, nil)}
  end

  @impl true
  def handle_event("select_package", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_id, id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-6xl">
      <:actions>
        <.button variant="ghost" size="sm" navigate={~p"/projects"} data-projects-link>
          <.lucide name="folder" class="size-4" /> Projects
        </.button>
      </:actions>

      <div data-screen="repository-kits" class="space-y-8">
        <header class="max-w-3xl">
          <p class="text-xs font-semibold uppercase tracking-[0.16em] text-primary">
            Repository integration
          </p>
          <h1 class="mt-2 text-2xl font-bold text-ink sm:text-3xl">SDD Kit Packages</h1>
          <p class="mt-3 text-sm leading-6 text-ink-muted">
            Every vendored kit package is immutable and inspectable: exact source, provenance,
            license, files, scripts, adapters, and permissions. This catalog is read-only.
          </p>
        </header>

        <div :if={@packages == []} data-empty-state>
          <.empty_state icon="folder-git-2" title="No SDD kit packages yet">
            <:description>
              Publish one with <code>mix repository_kits.publish</code> to make it inspectable here.
            </:description>
          </.empty_state>
        </div>

        <div
          :if={@packages != []}
          class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(20rem,0.9fr)]"
        >
          <section
            aria-labelledby="packages-heading"
            class="rounded-xl border border-line bg-surface p-4 sm:p-6"
          >
            <h2 id="packages-heading" class="text-base font-bold text-ink">Packages</h2>

            <ul class="mt-4 space-y-2" data-package-list>
              <li :for={package <- @packages} data-package-row data-package-id={package.id}>
                <button
                  type="button"
                  phx-click="select_package"
                  phx-value-id={package.id}
                  class={[
                    "w-full rounded-lg border px-3 py-2.5 text-left transition-colors",
                    if(@selected_id == package.id,
                      do: "border-primary bg-raised",
                      else: "border-line bg-canvas"
                    )
                  ]}
                >
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <span class="text-sm font-semibold text-ink" data-row-field="source">
                      {package.source}
                    </span>
                    <.badge variant="neutral">v{package.version}</.badge>
                  </div>
                  <p class="mt-1 text-xs text-ink-muted">
                    <span data-row-field="publisher">{package.publisher}</span>
                    &middot; <span data-row-field="license">{package.license}</span>
                    &middot; <span data-row-field="digest">{String.slice(package.digest, 0, 12)}</span>&hellip;
                    &middot;
                    <span data-row-field="inserted_at">
                      {Calendar.strftime(package.inserted_at, "%Y-%m-%d")}
                    </span>
                  </p>
                  <div
                    :if={superseded = RepositoryKits.superseded_by(package, @packages)}
                    data-superseded
                    class="mt-2"
                  >
                    <.badge variant="info">Superseded by v{superseded.version}</.badge>
                  </div>
                </button>
              </li>
            </ul>
          </section>

          <section
            :if={@selected_id}
            aria-labelledby="package-detail-heading"
            class="rounded-xl border border-line bg-surface p-4 sm:p-6"
            data-package-detail
          >
            <% package = Enum.find(@packages, &(&1.id == @selected_id)) %>
            <div :if={package}>
              <h2 id="package-detail-heading" class="text-base font-bold text-ink">
                Package details
              </h2>

              <dl class="mt-4 space-y-3 text-sm">
                <div>
                  <dt class="font-semibold text-ink-muted">Source</dt>
                  <dd data-detail="source" class="text-ink">{package.source}</dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Publisher</dt>
                  <dd data-detail="publisher" class="text-ink">{package.publisher}</dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Version</dt>
                  <dd data-detail="version" class="text-ink">{package.version}</dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Digest</dt>
                  <dd data-detail="digest" class="break-all font-mono text-xs text-ink">
                    {package.digest}
                  </dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">License</dt>
                  <dd data-detail="license" class="text-ink">{package.license}</dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Provenance</dt>
                  <dd data-detail="provenance" class="text-ink">
                    <span data-provenance="ref_type">{package.provenance["ref_type"]}</span>
                    &middot;
                    <span data-provenance="ref" class="break-all font-mono text-xs">
                      {package.provenance["ref"]}
                    </span>
                    &middot;
                    <span data-provenance="repository">{package.provenance["repository"]}</span>
                  </dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Supported adapters</dt>
                  <dd data-detail="supported_adapters" class="text-ink">
                    {Enum.join(package.supported_adapters, ", ")}
                  </dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Required permissions</dt>
                  <dd data-detail="required_permissions" class="text-ink">
                    {if package.required_permissions == [],
                      do: "None",
                      else: Enum.join(package.required_permissions, ", ")}
                  </dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Scripts</dt>
                  <dd data-detail="scripts" class="text-ink">
                    {if package.scripts == [],
                      do: "None",
                      else: Enum.join(package.scripts, ", ")}
                  </dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">Recorded</dt>
                  <dd data-detail="inserted_at" class="text-ink">
                    {DateTime.to_iso8601(package.inserted_at)}
                  </dd>
                </div>
                <div>
                  <dt class="font-semibold text-ink-muted">File manifest</dt>
                  <dd data-detail="file_manifest">
                    <ul class="mt-1 space-y-1" data-manifest-files>
                      <li
                        :for={file <- package.file_manifest["files"]}
                        data-manifest-file
                        data-path={file["path"]}
                        class="flex items-center justify-between gap-2 rounded border border-line bg-canvas px-2 py-1 text-xs"
                      >
                        <span class="font-mono">{file["path"]}</span>
                        <span class="text-ink-muted">
                          {file["size"]} bytes
                          <span :if={file["executable"]} data-executable>&middot; executable</span>
                        </span>
                      </li>
                    </ul>
                  </dd>
                </div>
              </dl>
            </div>
          </section>
        </div>
      </div>
    </.app_shell>
    """
  end
end
