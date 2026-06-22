defmodule Still.DeployLog do
  @moduledoc """
  Pure helpers for deploy-log capture and rendering.

  The journal shellout lives in `Still.Agent.DeployLogCollector`; everything
  here is side-effect free: capping a captured blob to a bounded tail, pulling
  the cursor out of `journalctl --show-cursor` output, dropping journalctl's
  own meta lines, and collapsing repeated lines for display.
  """

  @max_bytes 262_144
  @max_lines 2_000

  @doc """
  Trims a captured log to its tail: at most `max_lines` lines and `max_bytes`
  bytes, keeping the end (where a crash lands) and prepending a one-line notice
  when anything was dropped. The last line is always kept even if it alone
  exceeds the byte budget. Returns `""` for `nil` or empty input.
  """
  def cap_tail(text, max_bytes \\ @max_bytes, max_lines \\ @max_lines)
      when is_binary(text) or is_nil(text) do
    if text in [nil, ""] do
      ""
    else
      # Drop a trailing newline so journalctl output that ends in "\n" doesn't
      # leave a phantom blank last line (and skew the dropped-line count).
      lines = text |> String.trim_trailing("\n") |> String.split("\n")
      total = length(lines)
      kept = lines |> Enum.take(-max_lines) |> tail_within_bytes(max_bytes)

      case total - length(kept) do
        0 ->
          Enum.join(kept, "\n")

        dropped ->
          Enum.join(["… #{dropped} earlier line#{plural(dropped)} truncated" | kept], "\n")
      end
    end
  end

  @doc """
  Resolves a journal read into the blob to use. On a successful read the output
  is meta-stripped and tail-capped; on a read error the previous last-good blob
  is kept — a transient `journalctl` failure must never blank a captured crash,
  least of all on the final flush that gets persisted.
  """
  def resolve_read({:ok, output}, _last) when is_binary(output) do
    output |> strip_meta() |> cap_tail()
  end

  def resolve_read(:error, last) when is_binary(last), do: last

  @doc """
  Returns whichever blob has more content. Used on the final flush so a journal
  vacuum/rotation mid-deploy — which can make a later read return *fewer* lines
  than an earlier tick — can't shrink the persisted capture below what was
  already seen. The slot is being torn down at finalize, so no newer lines are
  arriving; more bytes means more retained context, never less.
  """
  def fuller(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) >= byte_size(b), do: a, else: b
  end

  @doc """
  Extracts the journal cursor from `journalctl --show-cursor` output — the
  trailing `-- cursor: <c>` line. Returns the cursor string, or `nil` when the
  output carries none.
  """
  def parse_cursor(output) when is_binary(output) do
    case Regex.run(~r/^-- cursor: (.+)$/m, output) do
      [_, cursor] -> String.trim(cursor)
      _ -> nil
    end
  end

  def parse_cursor(_output), do: nil

  @doc """
  Drops journalctl's own meta lines — the `-- No entries --`, `-- Boot … --`,
  and `-- cursor: … --` markers it prints alongside real log lines — leaving
  only the unit's output.
  """
  def strip_meta(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&meta_line?/1)
    |> Enum.join("\n")
  end

  @doc """
  Collapses consecutive repeated *blocks* so a crash-loop's cycles don't bury
  the root cause. Lines are compared by message — the journal timestamp, host,
  and pid prefix is ignored and digit runs (restart counters, pids) are
  normalized — so the near-identical cycles systemd emits on a `RestartSec` loop
  fold into one even though their timestamps and counters differ.

  A `p`-line block repeated `r` times (`r > 1`) renders the block once, verbatim
  with its real timestamps, followed by a `  … ×r` marker (`  … (p lines) ×r`
  for multi-line blocks). The first occurrence is always shown in full —
  collapsing only removes redundant repeats, never the crash itself.
  """
  def collapse_repeats(text) when is_binary(text) do
    lines = String.split(text, "\n")
    keys = Enum.map(lines, &dedup_key/1)

    lines
    |> run_length_encode(keys, [])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  # A block longer than this is not worth scanning for as a repeat; it also
  # bounds the cost of best_block/1 on a large capture.
  @max_block_period 40

  # Greedy block run-length encoding; `acc` is the output, reversed.
  defp run_length_encode([], _keys, acc), do: acc

  defp run_length_encode(lines, keys, acc) do
    case best_block(keys) do
      {period, reps} when reps > 1 ->
        block = Enum.take(lines, period)
        acc = [repeat_marker(period, reps) | Enum.reverse(block) ++ acc]
        consumed = period * reps
        run_length_encode(Enum.drop(lines, consumed), Enum.drop(keys, consumed), acc)

      _ ->
        run_length_encode(tl(lines), tl(keys), [hd(lines) | acc])
    end
  end

  # The leading block (period × reps, reps ≥ 2) that consumes the most lines;
  # `{1, 1}` when nothing at the front repeats.
  defp best_block(keys) do
    max_p = keys |> length() |> div(2) |> min(@max_block_period) |> max(1)

    Enum.reduce(1..max_p, {1, 1}, fn p, {bp, br} = best ->
      r = leading_reps(keys, p)
      if r >= 2 and p * r > bp * br, do: {p, r}, else: best
    end)
  end

  defp leading_reps(keys, period) do
    count_leading(keys, Enum.take(keys, period), period, 0)
  end

  defp count_leading(keys, block, period, acc) do
    case Enum.take(keys, period) do
      ^block -> count_leading(Enum.drop(keys, period), block, period, acc + 1)
      _ -> acc
    end
  end

  defp repeat_marker(1, reps), do: "  … ×#{reps}"
  defp repeat_marker(period, reps), do: "  … (#{period} lines) ×#{reps}"

  # Comparison key: strip the journal metadata prefix (timestamp/host/ident+pid)
  # and normalize digit runs so a restart counter or pid that ticks each cycle
  # doesn't defeat the match. Used only for dedup — the displayed text is intact.
  defp dedup_key(line) do
    line |> strip_journal_prefix() |> normalize_digits()
  end

  defp strip_journal_prefix(line) do
    case Regex.run(~r/^\S+ \S+ [^:]*: (.*)$/, line) do
      [_, message] -> message
      _ -> line
    end
  end

  defp normalize_digits(message), do: Regex.replace(~r/\d+/, message, "#")

  defp tail_within_bytes(lines, budget) do
    lines
    |> Enum.reverse()
    |> take_within(budget, [], 0)
  end

  defp take_within([], _budget, acc, _size), do: acc

  defp take_within([line | rest], budget, acc, size) do
    next = size + byte_size(line) + 1

    cond do
      # Always keep at least the final line — the crash sits at the very end.
      acc == [] -> take_within(rest, budget, [line], next)
      next > budget -> acc
      true -> take_within(rest, budget, [line | acc], next)
    end
  end

  defp meta_line?(line), do: String.starts_with?(line, "-- ")

  defp plural(1), do: ""
  defp plural(_n), do: "s"
end
