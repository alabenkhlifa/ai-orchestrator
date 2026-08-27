defmodule SddOrchestrator.Devices.PairingGuidance do
  @moduledoc """
  The one owned wording for telling someone how to get a pairing code.

  Three surfaces ask for a pairing code: accountless local onboarding, empty
  repository initialization, and the hosted project page that has to connect a
  machine. Each one used to carry its own copy of the sentences, and the three
  copies drifted apart. The wording lives here instead, as data, so every surface
  renders the same instructions and the no-terminal rule can be proved once.

  Two things the older wording got wrong are fixed here and must stay fixed:

    * A browser cannot see whether a native application is installed on the
      machine in front of it. The control plane only knows that no worker is
      paired, so the guidance may not assert that the app is missing. Installing
      it is offered as the alternative branch, not as the premise.
    * The worker app holds a live pairing code and offers it on its macOS menu
      bar status line, so the code is copied from a running app rather than read
      off a first-launch screen. Naming the menu bar is what makes the guidance
      match the app that ships.

  The supported macOS window is rendered from `WorkerDiscovery`'s computed
  policy rather than written out here, so this copy cannot drift from the policy
  it describes.

  `guidance/0` carries the two steps that obtain the code, which are identical
  everywhere. `paste_step/0` is separate because a surface may only show it when
  it actually offers a pairing field: the hosted project page hands the owner off
  without one, and promising a field it does not render would be a lie.
  """

  alias SddOrchestrator.Devices.WorkerDiscovery

  @type step :: %{title: String.t(), detail: String.t(), action: :open | :copy | :paste}

  @type guidance :: %{headline: String.t(), steps: [step()]}

  @doc """
  The headline and the steps that obtain a pairing code.

  These steps are the same on every surface, because getting the code out of the
  worker app does not depend on which page asked for it.
  """
  @spec guidance() :: guidance()
  def guidance do
    %{
      headline:
        "This Mac has no paired worker yet. If the worker app is already installed, the code you need is in its menu bar.",
      steps: [
        %{
          title: "Open the worker app",
          detail:
            "Look for its icon in the menu bar at the top of your screen. Not installed yet? Download it below, drag it to Applications, and open it. Works on macOS #{supported_macos_copy()}.",
          action: :open
        },
        %{
          title: "Copy the code",
          detail:
            ~s(Click the icon, then click the top line that says "Not paired". The code goes to your clipboard.),
          action: :copy
        }
      ]
    }
  end

  @doc """
  The step that spends the code, for a surface that renders a pairing field.

  Kept out of `guidance/0` so a page with no field cannot render it by accident.
  """
  @spec paste_step() :: step()
  def paste_step do
    %{
      title: "Paste it here",
      detail: "The code works once, and only on this Mac.",
      action: :paste
    }
  end

  # The supported window is the one `WorkerDiscovery` computes, never a literal.
  defp supported_macos_copy do
    WorkerDiscovery.compatibility_policy().os_majors |> Enum.join(" and ")
  end
end
