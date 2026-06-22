defmodule Still.DeployLogTest do
  use ExUnit.Case, async: true

  alias Still.DeployLog

  describe "cap_tail/3" do
    test "returns empty for nil or empty input" do
      assert DeployLog.cap_tail(nil) == ""
      assert DeployLog.cap_tail("") == ""
    end

    test "leaves text under both caps untouched" do
      text = "line one\nline two\nline three"
      assert DeployLog.cap_tail(text) == text
    end

    test "drops a trailing newline rather than leaving a phantom blank line" do
      assert DeployLog.cap_tail("line one\nline two\n") == "line one\nline two"
    end

    test "keeps the tail when the line cap is exceeded and notes the drop" do
      text = Enum.map_join(1..10, "\n", &"line #{&1}")

      capped = DeployLog.cap_tail(text, 100_000, 3)

      assert capped == "… 7 earlier lines truncated\nline 8\nline 9\nline 10"
    end

    test "keeps the tail (not the head) when the byte cap is exceeded" do
      text = Enum.map_join(1..10, "\n", fn _ -> "0123456789" end)

      # Budget 25 fits exactly the last two 10-byte lines (+newline); 8 dropped.
      # Pin the exact output so a too-aggressive trim or a head-keep regression fails.
      assert DeployLog.cap_tail(text, 25, 1_000) ==
               "… 8 earlier lines truncated\n0123456789\n0123456789"
    end

    test "always keeps the final line even if it alone exceeds the byte budget" do
      text = "short\n" <> String.duplicate("x", 500)

      capped = DeployLog.cap_tail(text, 10, 1_000)

      assert capped == "… 1 earlier line truncated\n" <> String.duplicate("x", 500)
    end

    test "uses the singular noun for a single dropped line" do
      text = "a\nb\nc"
      assert DeployLog.cap_tail(text, 100_000, 2) =~ "… 1 earlier line truncated"
    end
  end

  describe "parse_cursor/1" do
    test "extracts the cursor from --show-cursor output" do
      output = "-- No entries --\n-- cursor: s=abc;i=1;b=2;m=3;t=4;x=5\n"
      assert DeployLog.parse_cursor(output) == "s=abc;i=1;b=2;m=3;t=4;x=5"
    end

    test "returns nil when no cursor line is present" do
      assert DeployLog.parse_cursor("some log line\nanother") == nil
    end

    test "returns nil for non-binary input" do
      assert DeployLog.parse_cursor(nil) == nil
    end
  end

  describe "strip_meta/1" do
    test "drops journalctl meta lines and keeps real output" do
      text =
        "-- Boot 7135c0 --\n2026-06-21T15:00:00+00:00 host app[1]: booting\n-- No entries --"

      assert DeployLog.strip_meta(text) ==
               "2026-06-21T15:00:00+00:00 host app[1]: booting"
    end
  end

  describe "resolve_read/2" do
    test "processes a successful read — strips meta and caps" do
      assert DeployLog.resolve_read({:ok, "-- Boot abc --\nthe crash line"}, "stale") ==
               "the crash line"
    end

    test "keeps the last-good blob on a read error, never blanking a capture" do
      # This is the core data-loss guard: a transient journalctl failure on the
      # FINAL flush must not persist "" over a captured crash.
      assert DeployLog.resolve_read(:error, "name forge@host in use — boot crash") ==
               "name forge@host in use — boot crash"

      refute DeployLog.resolve_read(:error, "the crash") == ""
    end
  end

  describe "collapse_repeats/1" do
    test "collapses runs of identical consecutive lines" do
      assert DeployLog.collapse_repeats("crash\ncrash\ncrash") == "crash\n  … ×3"
    end

    test "leaves single and non-consecutive lines alone" do
      assert DeployLog.collapse_repeats("a\nb\na") == "a\nb\na"
    end

    test "collapses a repeated multi-line block to one block plus a count" do
      block = "boot failed\nstack frame\nrestarting"
      text = Enum.map_join(1..4, "\n", fn _ -> block end)

      assert DeployLog.collapse_repeats(text) ==
               "boot failed\nstack frame\nrestarting\n  … (3 lines) ×4"
    end

    test "folds real crash-loop cycles despite changing timestamps, pids, and counters" do
      # The cycles differ only in timestamp, pid, and the restart counter — the
      # message-keyed, digit-normalized comparison must still see them as repeats.
      journal =
        """
        2026-06-21T15:00:01+0000 host app@blue[101]: ** (RuntimeError) boom
        2026-06-21T15:00:01+0000 host systemd[1]: app@blue.service: Failed with result 'exit-code'.
        2026-06-21T15:00:03+0000 host systemd[1]: app@blue.service: restart counter is at 1.
        2026-06-21T15:00:03+0000 host app@blue[102]: ** (RuntimeError) boom
        2026-06-21T15:00:03+0000 host systemd[1]: app@blue.service: Failed with result 'exit-code'.
        2026-06-21T15:00:05+0000 host systemd[1]: app@blue.service: restart counter is at 2.
        2026-06-21T15:00:05+0000 host app@blue[103]: ** (RuntimeError) boom
        2026-06-21T15:00:05+0000 host systemd[1]: app@blue.service: Failed with result 'exit-code'.
        2026-06-21T15:00:07+0000 host systemd[1]: app@blue.service: restart counter is at 3.
        """
        |> String.trim()

      collapsed = DeployLog.collapse_repeats(journal)

      # The crash reason survives, shown once with its real (first) timestamp…
      assert collapsed =~ "2026-06-21T15:00:01+0000 host app@blue[101]: ** (RuntimeError) boom"
      # …and the redundant cycles fold into a single count.
      assert collapsed =~ "  … (3 lines) ×3"
      # Only one copy of the crash remains in the rendered output.
      assert collapsed |> String.split("** (RuntimeError) boom") |> length() == 2
    end
  end

  describe "fuller/2" do
    test "returns the blob with more content" do
      assert DeployLog.fuller("aaaa", "bb") == "aaaa"
      assert DeployLog.fuller("bb", "aaaa") == "aaaa"
    end
  end
end
