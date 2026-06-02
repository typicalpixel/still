#!/usr/bin/env bats

# Smoke tests for the built release tarball.
#
# These tests extract the actual mix release and run `bin/still eval`
# against it with only an env file for configuration — the same path an
# operator takes when running `bin/still remote` / `eval` / `rpc`
# outside of systemd.
#
# They catch bugs that unit/integration tests can't reach:
#
#   * rel/env.sh.eex not sourcing /etc/still/still.env correctly
#     (e.g. missing `set -a` so sourced vars aren't exported)
#   * Runtime env var wiring between install.sh, env files, and
#     runtime.exs
#
# Skipped when no built tarball exists under _build/prod/. Build with
# `MIX_ENV=prod mix release --overwrite` first. On CI the release
# should be built in an earlier step.

setup() {
  TEST_DIR=$(mktemp -d)
  ETC="$TEST_DIR/etc"
  RELEASE_DIR="$TEST_DIR/release"
  mkdir -p "$ETC" "$RELEASE_DIR"

  TARBALL=$(ls "$BATS_TEST_DIRNAME"/../../_build/prod/still-*.tar.gz 2>/dev/null | head -n1)

  if [ -z "$TARBALL" ]; then
    skip "no release tarball at _build/prod/still-*.tar.gz; build with MIX_ENV=prod mix release --overwrite"
  fi

  tar -xzf "$TARBALL" -C "$RELEASE_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Writes a minimal env file for STILL_MODE=agent (fewest runtime.exs
# requirements — no DATABASE_PATH / SECRET_KEY_BASE). Callers append
# their own canary lines.
write_agent_env_file() {
  cat > "$ETC/still.env" <<EOF
STILL_MODE=agent
STILL_NODE_HOST=127.0.0.1
STILL_CONTROLLER_NODE=still@127.0.0.1
STILL_SERVER_ID=00000000-0000-0000-0000-000000000000
RELEASE_COOKIE=smoke-test-cookie
EOF
}

@test "env.sh sources still.env and exports vars so bin/still eval sees them" {
  write_agent_env_file
  echo 'SMOKE_CANARY=env-sourcing-works-abc123' >> "$ETC/still.env"

  run env -i HOME="$HOME" PATH="$PATH" STILL_ETC="$ETC" \
    "$RELEASE_DIR/bin/still" eval 'IO.puts(System.get_env("SMOKE_CANARY"))'

  [ "$status" -eq 0 ]
  [[ "$output" == *"env-sourcing-works-abc123"* ]]
}

@test "env.sh sources still.env.local in addition to still.env" {
  write_agent_env_file

  cat > "$ETC/still.env.local" <<EOF
SMOKE_LOCAL_CANARY=local-file-also-sourced-xyz789
EOF

  run env -i HOME="$HOME" PATH="$PATH" STILL_ETC="$ETC" \
    "$RELEASE_DIR/bin/still" eval 'IO.puts(System.get_env("SMOKE_LOCAL_CANARY"))'

  [ "$status" -eq 0 ]
  [[ "$output" == *"local-file-also-sourced-xyz789"* ]]
}

@test "env.sh.local values override still.env (local wins by being sourced second)" {
  write_agent_env_file
  echo 'OVERRIDE_ME=from-still-env' >> "$ETC/still.env"

  cat > "$ETC/still.env.local" <<EOF
OVERRIDE_ME=from-still-env-local
EOF

  run env -i HOME="$HOME" PATH="$PATH" STILL_ETC="$ETC" \
    "$RELEASE_DIR/bin/still" eval 'IO.puts(System.get_env("OVERRIDE_ME"))'

  [ "$status" -eq 0 ]
  [[ "$output" == *"from-still-env-local"* ]]
}

@test "env.sh honors STILL_ETC override for non-default install prefixes" {
  # Prove STILL_ETC is actually consulted: put the env file at a
  # completely different path, pass that path via STILL_ETC, and
  # confirm sourcing still happens.
  alt_etc="$TEST_DIR/alt-prefix/etc/still"
  mkdir -p "$alt_etc"

  cat > "$alt_etc/still.env" <<EOF
STILL_MODE=agent
STILL_NODE_HOST=127.0.0.1
STILL_CONTROLLER_NODE=still@127.0.0.1
STILL_SERVER_ID=00000000-0000-0000-0000-000000000000
RELEASE_COOKIE=smoke-test-cookie
ALT_ETC_CANARY=alt-prefix-works
EOF

  run env -i HOME="$HOME" PATH="$PATH" STILL_ETC="$alt_etc" \
    "$RELEASE_DIR/bin/still" eval 'IO.puts(System.get_env("ALT_ETC_CANARY"))'

  [ "$status" -eq 0 ]
  [[ "$output" == *"alt-prefix-works"* ]]
}
