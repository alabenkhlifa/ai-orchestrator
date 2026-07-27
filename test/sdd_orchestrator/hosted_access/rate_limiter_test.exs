defmodule SddOrchestrator.HostedAccess.RateLimiterTest do
  use ExUnit.Case, async: false

  alias SddOrchestrator.HostedAccess.RateLimiter

  setup do
    RateLimiter.reset()
    :ok
  end

  test "limits one email without retaining its raw value" do
    decisions =
      for _request <- 1..6 do
        RateLimiter.allow?("private@example.com", {198, 51, 100, 1})
      end

    assert decisions == [true, true, true, true, true, false]

    state = :sys.get_state(RateLimiter) |> inspect()
    refute state =~ "private@example.com"
    refute state =~ "198.51.100.1"
  end

  test "limits one source IP across otherwise independent emails" do
    decisions =
      for request <- 1..21 do
        RateLimiter.allow?("person-#{request}@example.com", {198, 51, 100, 2})
      end

    assert Enum.take(decisions, 20) == List.duplicate(true, 20)
    assert List.last(decisions) == false
  end

  test "enforces the global send cap across independent email and IP buckets" do
    decisions =
      for request <- 1..101 do
        RateLimiter.allow?(
          "global-#{request}@example.com",
          "203.0.113.#{request}"
        )
      end

    assert Enum.take(decisions, 100) == List.duplicate(true, 100)
    assert List.last(decisions) == false
  end
end
