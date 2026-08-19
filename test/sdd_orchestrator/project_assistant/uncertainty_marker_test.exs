defmodule SddOrchestrator.ProjectAssistant.UncertaintyMarkerTest do
  @moduledoc """
  specs/12-project-assistant Task 7 focused proof: the closed, typed
  uncertainty-marker vocabulary (AC-12).
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.UncertaintyMarker

  test "kinds/0 is exactly the closed six" do
    assert Enum.sort(UncertaintyMarker.kinds()) ==
             Enum.sort([:partial, :stale, :excluded, :unavailable, :conflicting, :unstable])
  end

  test "new/2 and to_map/1 round-trip to a plain string-keyed map" do
    marker = UncertaintyMarker.new(:unstable, "the tree changed during the scan")
    assert marker == %{type: :unstable, detail: "the tree changed during the scan"}

    assert UncertaintyMarker.to_map(marker) == %{
             "type" => "unstable",
             "detail" => "the tree changed during the scan"
           }
  end

  test "from_candidate/1 accepts only a known kind with a non-empty detail" do
    assert {:ok, %{type: :partial, detail: "only some of this could be answered"}} =
             UncertaintyMarker.from_candidate(%{
               type: :partial,
               detail: "only some of this could be answered"
             })

    assert {:error, :invalid_marker} =
             UncertaintyMarker.from_candidate(%{type: :partial, detail: ""})

    assert {:error, :invalid_marker} =
             UncertaintyMarker.from_candidate(%{type: :made_up, detail: "x"})

    assert {:error, :invalid_marker} =
             UncertaintyMarker.from_candidate(%{detail: "no type at all"})

    assert {:error, :invalid_marker} = UncertaintyMarker.from_candidate("not even a map")
  end
end
