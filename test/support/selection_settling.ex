defmodule SddOrchestrator.SelectionSettling do
  @moduledoc """
  Waits for a page that asked a machine a question to settle on its answer.

  A folder request is answered out of band: the click renders a waiting state
  and the outcome arrives as a message a moment later. A test that reads the
  page once after the click reads the waiting state and reports a product
  failure that is really a timing assumption.

  `settle/3` re-reads the page until the expected markup is there, and then
  asserts on it, so a page that never settles fails on the assertion itself with
  the rendered markup rather than on a timeout with nothing to look at. It only
  removes the assumption about when; the assertion is unchanged.

  Use it only where an answer genuinely arrives out of band. A test that
  controls the outcome itself, through
  `SddOrchestrator.RepositorySelectionTransportDouble`, already knows the
  message was sent before it renders and needs no waiting at all.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest, only: [render: 1]

  @poll_interval 20
  @default_timeout 5_000
  @waiting "data-selection-waiting"

  @doc """
  Renders `view` until it contains `needle`, and returns that markup.

  Fails through the assertion once `timeout` milliseconds have passed, so the
  failure names the markup that was actually rendered.
  """
  @spec settle(term(), String.t(), pos_integer()) :: String.t()
  def settle(view, needle, timeout \\ @default_timeout) do
    until(view, needle, System.monotonic_time(:millisecond) + timeout)
  end

  @doc """
  Renders `view` until it is no longer waiting on a machine, and returns that
  markup.

  Use this where the expected markup was already on the page before the click,
  such as a connected project moving to a different machine: waiting for
  `connected` there would pass on the state the page was already in.
  """
  @spec settled(term(), pos_integer()) :: String.t()
  def settled(view, timeout \\ @default_timeout) do
    answered(view, System.monotonic_time(:millisecond) + timeout)
  end

  defp until(view, needle, deadline) do
    html = render(view)

    if html =~ needle or System.monotonic_time(:millisecond) >= deadline do
      assert html =~ needle
      html
    else
      Process.sleep(@poll_interval)
      until(view, needle, deadline)
    end
  end

  defp answered(view, deadline) do
    html = render(view)

    if not (html =~ @waiting) or System.monotonic_time(:millisecond) >= deadline do
      refute html =~ @waiting
      html
    else
      Process.sleep(@poll_interval)
      answered(view, deadline)
    end
  end
end
