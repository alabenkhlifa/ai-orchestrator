defmodule SddOrchestrator.Devices.PairingGuidanceTest do
  @moduledoc """
  Proof for the single owned wording that tells someone how to get a pairing
  code.

  The wording used to be written out on three surfaces and had drifted. Two
  claims in the old copy were wrong and must not come back: that the worker app
  is not installed, which a browser cannot know, and that the app shows a code
  the first time it is opened, when it actually offers a live code on its macOS
  menu bar status line.
  """

  use ExUnit.Case, async: true

  alias SddOrchestrator.Devices.{PairingGuidance, WorkerDiscovery}

  # Shell-command shapes that would mean the user was asked to use a terminal.
  @terminal_markers [
    "terminal",
    "command",
    "shell",
    "sudo",
    "brew ",
    "curl ",
    "npm ",
    "git ",
    "chmod",
    "$ ",
    ">_"
  ]

  test "the headline points at the menu bar without claiming the app is missing" do
    headline = PairingGuidance.guidance().headline

    assert headline =~ "menu bar"
    assert headline =~ "no paired worker"

    # A browser cannot see an installed application, so the copy may only say
    # what the control plane knows: nothing is paired.
    assert headline =~ "If the worker app is already installed"
    refute headline =~ "Install the worker app"
    refute headline =~ "No worker is set up"
  end

  test "opening the app is the premise and installing it is the alternative branch" do
    [open_step, _copy] = PairingGuidance.guidance().steps

    assert open_step.action == :open
    assert open_step.title == "Open the worker app"
    assert open_step.detail =~ "Look for its icon in the menu bar"
    assert open_step.detail =~ "Not installed yet?"
    assert open_step.detail =~ "drag it to Applications"
  end

  test "copying the code names the click-to-copy status line" do
    [_open, copy_step] = PairingGuidance.guidance().steps

    assert copy_step.action == :copy
    assert copy_step.title == "Copy the code"
    assert copy_step.detail =~ ~s(the top line that says "Not paired")
    assert copy_step.detail =~ "goes to your clipboard"

    # The app holds a live code, so nothing may promise a first-launch screen.
    refute copy_step.detail =~ "first time"
  end

  test "the supported macOS window is rendered from the computed policy" do
    [open_step, _copy] = PairingGuidance.guidance().steps
    majors = WorkerDiscovery.compatibility_policy().os_majors

    assert open_step.detail =~ "Works on macOS #{Enum.join(majors, " and ")}."

    for major <- majors do
      assert open_step.detail =~ major
    end
  end

  test "the paste step is separate so a page with no field cannot render it" do
    paste = PairingGuidance.paste_step()

    assert paste.action == :paste
    assert paste.title == "Paste it here"
    assert paste.detail == "The code works once, and only on this Mac."

    actions = Enum.map(PairingGuidance.guidance().steps, & &1.action)
    assert actions == [:open, :copy]
    refute paste in PairingGuidance.guidance().steps
  end

  test "no part of the guidance asks for a terminal" do
    copy = String.downcase(all_copy())

    for marker <- @terminal_markers do
      refute String.contains?(copy, marker)
    end
  end

  test "the guidance carries no em dash" do
    refute all_copy() =~ "—"
  end

  defp all_copy do
    guidance = PairingGuidance.guidance()

    [
      guidance.headline
      | Enum.flat_map(guidance.steps ++ [PairingGuidance.paste_step()], &[&1.title, &1.detail])
    ]
    |> Enum.join(" ")
  end
end
