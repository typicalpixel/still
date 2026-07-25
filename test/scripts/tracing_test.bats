#!/usr/bin/env bats

# Test suite for rel/overlays/bin/tracing — the Day-2 toggle an operator runs
# directly (install.sh delegates to the same script; see install_test.bats).
#
# Stubs intercept systemctl and curl so tests run without root and without a
# collector. All writes land in a temp directory via STILL_ETC and
# STILL_TRACING_DROPIN.

setup() {
  TEST_DIR=$(mktemp -d)
  STUB_BIN="$TEST_DIR/stub_bin"
  STUB_LOG="$TEST_DIR/stub_log"
  mkdir -p "$STUB_BIN" "$STUB_LOG"

  # systemctl: log invocations. `is-active` succeeds only for units whose
  # marker file exists, so tests choose which services are "running";
  # `restart <unit>` fails when a fail_restart_<unit> marker exists.
  cat > "$STUB_BIN/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$STUB_LOG/systemctl.log"
if [ "\$1" = "is-active" ]; then
  for arg in "\$@"; do
    case "\$arg" in
      *.service) [ -f "$STUB_LOG/active_\$arg" ] && exit 0 || exit 1 ;;
    esac
  done
  exit 1
fi
if [ "\$1" = "restart" ] && [ -f "$STUB_LOG/fail_restart_\$2" ]; then
  exit 1
fi
exit 0
STUB

  # curl: a collector answers only when the marker exists.
  cat > "$STUB_BIN/curl" <<STUB
#!/bin/sh
echo "\$*" >> "$STUB_LOG/curl.log"
[ -f "$STUB_LOG/collector_up" ]
STUB

  chmod +x "$STUB_BIN"/*

  export PATH="$STUB_BIN:$PATH"
  export STILL_ETC="$TEST_DIR/etc/still"
  export STILL_TRACING_DROPIN="$TEST_DIR/caddy-tracing.conf"
  mkdir -p "$STILL_ETC"

  ENV_LOCAL="$STILL_ETC/still.env.local"
  TRACING="${BATS_TEST_DIRNAME}/../../rel/overlays/bin/tracing"
}

teardown() {
  rm -rf "$TEST_DIR"
}

mark_active() { touch "$STUB_LOG/active_$1"; }

write_mode() { echo "STILL_MODE=$1" > "$STILL_ETC/still.env"; }

# Shadows any real caddy on PATH with a stub reporting the given version.
write_caddy_stub() {
  cat > "$STUB_BIN/caddy" <<EOF
#!/bin/sh
[ "\$1" = version ] && echo "$1 h1:stub"
exit 0
EOF
  chmod +x "$STUB_BIN/caddy"
}

@test "on: names a controller's Caddy caddy-ingress so the hops read apart" {
  write_mode controller
  run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_SERVICE_NAME=caddy-ingress$' "$STILL_TRACING_DROPIN"
  grep -q '^STILL_OTLP_SERVICE_NAME=caddy-ingress$' "$ENV_LOCAL"
}

@test "on: names an agent's Caddy caddy — it serves the application itself" {
  write_mode agent
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"
}

@test "on: standalone is a single hop, so it is caddy too" {
  write_mode standalone
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"
}

@test "on: falls back to caddy when there is no env file to read a mode from" {
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"
}

@test "on: an explicit service name beats the mode-derived default" {
  write_mode controller
  STILL_OTLP_SERVICE_NAME=edge run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^Environment=OTEL_SERVICE_NAME=edge$' "$STILL_TRACING_DROPIN"
}

@test "on: a name already recorded is never renamed by the mode default" {
  # An install that enabled tracing before this default existed has
  # STILL_OTLP_SERVICE_NAME=caddy on file; an upgrade must not rename its
  # service out from under whatever is already querying it.
  write_mode controller
  printf 'STILL_CADDY_TRACING=1\nSTILL_OTLP_SERVICE_NAME=caddy\n' > "$ENV_LOCAL"

  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"
}

@test "on: writes the drop-in, the flag, and daemon-reloads" {
  run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf$' "$STILL_TRACING_DROPIN"
  grep -q '^Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318$' "$STILL_TRACING_DROPIN"
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"
  grep -q '^\[Service\]$' "$STILL_TRACING_DROPIN"

  grep -q '^STILL_CADDY_TRACING=1$' "$ENV_LOCAL"
  grep -q 'daemon-reload' "$STUB_LOG/systemctl.log"
}

@test "on: warns when nothing is listening at the endpoint" {
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing answered at http://127.0.0.1:4318"* ]]
}

@test "on: stays quiet about the collector when one answers" {
  touch "$STUB_LOG/collector_up"
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" != *"nothing answered"* ]]
}

@test "on: restarts caddy only when it is running" {
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  ! grep -q 'restart caddy.service' "$STUB_LOG/systemctl.log"
  [[ "$output" == *"isn't running"* ]]

  rm -f "$STILL_TRACING_DROPIN" "$ENV_LOCAL"
  mark_active caddy.service
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q 'restart caddy.service' "$STUB_LOG/systemctl.log"
}

@test "on: restarts still so it picks up the flag when it is running" {
  mark_active still.service
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q 'restart still.service' "$STUB_LOG/systemctl.log"
}

@test "on: is idempotent — a second run changes nothing and restarts nothing" {
  mark_active caddy.service
  mark_active still.service
  run sh "$TRACING" on
  [ "$status" -eq 0 ]

  rm -f "$STUB_LOG/systemctl.log"
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on"* ]]
  [ ! -f "$STUB_LOG/systemctl.log" ]
}

@test "on: honors STILL_OTLP_ENDPOINT and persists it for later runs" {
  STILL_OTLP_ENDPOINT=http://10.0.0.9:4318 run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.0.9:4318$' "$STILL_TRACING_DROPIN"
  grep -q '^STILL_OTLP_ENDPOINT=http://10.0.0.9:4318$' "$ENV_LOCAL"

  # A later run with nothing in the environment reads it back from the file
  # rather than reverting to the default.
  run sh "$TRACING" status
  [[ "$output" == *"http://10.0.0.9:4318"* ]]
}

@test "on: caller environment beats the value stored in still.env.local" {
  STILL_OTLP_ENDPOINT=http://10.0.0.9:4318 run sh "$TRACING" on
  [ "$status" -eq 0 ]

  STILL_OTLP_ENDPOINT=http://10.0.0.10:4318 run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.0.10:4318$' "$STILL_TRACING_DROPIN"
}

@test "on: honors STILL_OTLP_PROTOCOL and STILL_OTLP_SERVICE_NAME" {
  STILL_OTLP_PROTOCOL=grpc STILL_OTLP_SERVICE_NAME=caddy-ingress run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_EXPORTER_OTLP_PROTOCOL=grpc$' "$STILL_TRACING_DROPIN"
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy-ingress$' "$STILL_TRACING_DROPIN"
}

@test "on: a later plain run does not revert a customised service name" {
  # Distinguishing the controller's ingress hop from an agent's in a multi-node
  # trace is a one-off command; it must not wash out on the next upgrade.
  STILL_OTLP_SERVICE_NAME=caddy-ingress run sh "$TRACING" on
  [ "$status" -eq 0 ]
  grep -q '^STILL_OTLP_SERVICE_NAME=caddy-ingress$' "$ENV_LOCAL"

  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on"* ]]
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy-ingress$' "$STILL_TRACING_DROPIN"

  run sh "$TRACING" status
  [[ "$output" == *"service:  caddy-ingress"* ]]
}

@test "on: omits OTEL_RESOURCE_ATTRIBUTES unless asked for" {
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  ! grep -q 'OTEL_RESOURCE_ATTRIBUTES' "$STILL_TRACING_DROPIN"
}

@test "on: passes resource attributes through and persists them" {
  # The escape hatch for a collector that doesn't stamp the environment onto
  # what it receives. Still doesn't interpret the value.
  STILL_OTLP_RESOURCE_ATTRIBUTES='deployment.environment=production,team=platform' \
    run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production,team=platform$' \
    "$STILL_TRACING_DROPIN"
  grep -q '^STILL_OTLP_RESOURCE_ATTRIBUTES=deployment.environment=production,team=platform$' \
    "$ENV_LOCAL"

  # Recorded, so a later plain run rebuilds the same drop-in.
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on"* ]]
  grep -q 'OTEL_RESOURCE_ATTRIBUTES=deployment.environment=production' "$STILL_TRACING_DROPIN"
}

@test "on: does not disturb other still.env.local entries" {
  printf 'SECRET_KEY_BASE=keepme\nRELEASE_COOKIE=alsokeep\n' > "$ENV_LOCAL"

  run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^SECRET_KEY_BASE=keepme$' "$ENV_LOCAL"
  grep -q '^RELEASE_COOKIE=alsokeep$' "$ENV_LOCAL"
  grep -q '^STILL_CADDY_TRACING=1$' "$ENV_LOCAL"
}

@test "off: removes the drop-in and the flag, keeping other entries" {
  printf 'SECRET_KEY_BASE=keepme\n' > "$ENV_LOCAL"
  run sh "$TRACING" on
  [ "$status" -eq 0 ]

  mark_active caddy.service
  run sh "$TRACING" off
  [ "$status" -eq 0 ]

  [ ! -f "$STILL_TRACING_DROPIN" ]
  ! grep -q 'STILL_CADDY_TRACING' "$ENV_LOCAL"
  grep -q '^SECRET_KEY_BASE=keepme$' "$ENV_LOCAL"
  grep -q 'restart caddy.service' "$STUB_LOG/systemctl.log"
}

@test "off: is idempotent when tracing was never on" {
  run sh "$TRACING" off
  [ "$status" -eq 0 ]
  [[ "$output" == *"already off"* ]]
  [ ! -f "$STUB_LOG/systemctl.log" ]
}

@test "status: reports off, then on, and whether a collector answers" {
  run sh "$TRACING" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracing:  off"* ]]
  [[ "$output" == *"(absent)"* ]]
  [[ "$output" == *"NOT reachable"* ]]

  touch "$STUB_LOG/collector_up"
  run sh "$TRACING" on
  run sh "$TRACING" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracing:  on"* ]]
  [[ "$output" == *"(present)"* ]]
  [[ "$output" == *"collector: reachable"* ]]
}

@test "on: leaves no temp files behind and keeps still.env.local root-only" {
  # still.env.local carries SECRET_KEY_BASE / RELEASE_COOKIE; nothing written
  # beside it may be world-readable, even transiently, and an interrupted run
  # must not strand a copy of the secrets in a .tmp file.
  run sh "$TRACING" on
  [ "$status" -eq 0 ]

  [ -z "$(find "$STILL_ETC" -name '*.tmp.*' -print)" ]
  [ "$(stat -c %a "$ENV_LOCAL")" = "600" ]
  # The caddy drop-in must stay world-readable despite the tightened umask.
  [ "$(stat -c %a "$STILL_TRACING_DROPIN")" = "644" ]
}

@test "on: refuses values with whitespace instead of writing a broken env file" {
  # Unquoted KEY=v alue in a sh-sourced file executes 'alue' as root on the
  # next run — refuse loudly rather than truncate silently.
  STILL_OTLP_RESOURCE_ATTRIBUTES='deployment.environment=prod east' \
    run sh "$TRACING" on
  [ "$status" -eq 65 ]
  [[ "$output" == *"must not contain whitespace"* ]]
  ! grep -q 'prod east' "$ENV_LOCAL" 2>/dev/null || false
}

@test "on: STILL_TRACING_SKIP_STILL_RESTART leaves still.service to the caller" {
  # install.sh sets this: it restarts still.service itself after the
  # pre-upgrade DB backup and migrations, and a restart here would boot the
  # new release (which migrates on boot) ahead of both.
  mark_active still.service
  STILL_TRACING_SKIP_STILL_RESTART=1 run sh "$TRACING" on
  [ "$status" -eq 0 ]

  grep -q '^STILL_CADDY_TRACING=1$' "$ENV_LOCAL"
  ! grep -q 'restart still.service' "$STUB_LOG/systemctl.log"
}

@test "on: a failed caddy restart warns and finishes instead of aborting half-applied" {
  mark_active caddy.service
  touch "$STUB_LOG/fail_restart_caddy.service"

  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"restart of caddy.service failed"* ]]
  [[ "$output" == *"systemctl restart caddy.service"* ]]
  # Both halves are still fully written for the manual restart to pick up.
  grep -q '^STILL_CADDY_TRACING=1$' "$ENV_LOCAL"
  [ -f "$STILL_TRACING_DROPIN" ]
}

@test "on: warns when Caddy predates 2.11 and would ignore http/protobuf" {
  write_caddy_stub v2.10.0
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignores OTEL_EXPORTER_OTLP_PROTOCOL"* ]]
  [[ "$output" == *"2.11"* ]]
}

@test "on: no version warning on Caddy >= 2.11 or when protocol is grpc" {
  write_caddy_stub v2.11.4
  run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignores OTEL_EXPORTER_OTLP_PROTOCOL"* ]]

  rm -f "$STILL_TRACING_DROPIN" "$ENV_LOCAL"
  write_caddy_stub v2.9.0
  STILL_OTLP_PROTOCOL=grpc run sh "$TRACING" on
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignores OTEL_EXPORTER_OTLP_PROTOCOL"* ]]
}

@test "status: agrees with Still about 'true' and about the flag living in still.env" {
  # runtime.exs accepts "1" or "true" from either env file; status must not
  # report "off" on a node that is actually emitting tracing handlers.
  echo 'STILL_CADDY_TRACING=true' > "$ENV_LOCAL"
  run sh "$TRACING" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracing:  on"* ]]

  rm -f "$ENV_LOCAL"
  printf 'STILL_MODE=standalone\nSTILL_CADDY_TRACING=1\n' > "$STILL_ETC/still.env"
  run sh "$TRACING" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracing:  on"* ]]
}

@test "rejects an unknown subcommand" {
  run sh "$TRACING" sideways
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage: tracing on|off|status"* ]]
}
