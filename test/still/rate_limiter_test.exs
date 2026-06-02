defmodule Still.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Still.RateLimiter

  describe "hit/4" do
    test "allows up to max hits in the window, then rejects with a retry-after" do
      pid = start_supervised!({RateLimiter, name: :rl_hit})

      assert :ok = RateLimiter.hit(:rl_hit, "k", 3, 60_000)
      assert :ok = RateLimiter.hit(:rl_hit, "k", 3, 60_000)
      assert :ok = RateLimiter.hit(:rl_hit, "k", 3, 60_000)
      assert {:error, retry_after} = RateLimiter.hit(:rl_hit, "k", 3, 60_000)
      assert is_integer(retry_after) and retry_after >= 1

      # A different key has its own budget.
      assert :ok = RateLimiter.hit(:rl_hit, "other", 3, 60_000)
      assert Process.alive?(pid)
    end

    test "reset clears all buckets" do
      start_supervised!({RateLimiter, name: :rl_reset})

      assert :ok = RateLimiter.hit(:rl_reset, "k", 1, 60_000)
      assert {:error, _} = RateLimiter.hit(:rl_reset, "k", 1, 60_000)

      assert :ok = RateLimiter.reset(:rl_reset)
      assert :ok = RateLimiter.hit(:rl_reset, "k", 1, 60_000)
    end

    test "a sweep keeps live buckets" do
      pid = start_supervised!({RateLimiter, name: :rl_sweep})

      assert :ok = RateLimiter.hit(:rl_sweep, "k", 2, 60_000)
      send(pid, :sweep)
      # The next call is processed after the :sweep message; the live bucket
      # survived, so this hit is still counted (and the third trips the limit).
      assert :ok = RateLimiter.hit(:rl_sweep, "k", 2, 60_000)
      assert {:error, _} = RateLimiter.hit(:rl_sweep, "k", 2, 60_000)
    end
  end

  describe "prune/3" do
    test "drops idle buckets and keeps recent ones" do
      buckets = %{"old" => {1, 0}, "new" => {1, 5_000}}
      assert RateLimiter.prune(buckets, 6_000, 3_000) == %{"new" => {1, 5_000}}
    end
  end
end
