#!/usr/bin/env bats

# Test suite for scripts/install.sh
#
# Stubs intercept privileged commands (systemctl, id, etc.) so tests run
# without root. All file writes land in a temp directory via STILL_PREFIX,
# STILL_ETC, STILL_VAR overrides.

setup() {
  TEST_DIR=$(mktemp -d)
  STUB_BIN="$TEST_DIR/stub_bin"
  STUB_LOG="$TEST_DIR/stub_log"
  mkdir -p "$STUB_BIN" "$STUB_LOG"

  # -- Stubs ----------------------------------------------------------

  # id: pretend to be root
  cat > "$STUB_BIN/id" <<'STUB'
#!/bin/sh
echo "0"
STUB

  # uname: report Linux
  cat > "$STUB_BIN/uname" <<'STUB'
#!/bin/sh
echo "Linux"
STUB

  # systemctl: log invocations, report service state via a marker file so
  # `is-active` returns "active" only after start/restart/enable-now has
  # run. Tests can pre-touch the marker to simulate a service that was
  # already running before the installer started.
  cat > "$STUB_BIN/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$STUB_LOG/systemctl.log"
case "\$1" in
  is-active)
    [ -f "$STUB_LOG/service_active" ]
    ;;
  start|restart)
    touch "$STUB_LOG/service_active"
    ;;
  enable)
    [ "\$2" = "--now" ] && touch "$STUB_LOG/service_active"
    ;;
esac
STUB

  # caddy: present on PATH; report a version that satisfies install's
  # >= 2.9.0 floor for per-host metrics.
  cat > "$STUB_BIN/caddy" <<'STUB'
#!/bin/sh
case "$1" in
  version) echo "v2.9.0 h1:stub" ;;
  *) exit 0 ;;
esac
STUB

  # hostname: return a predictable IP
  cat > "$STUB_BIN/hostname" <<'STUB'
#!/bin/sh
echo "10.0.0.99"
STUB

  # uuidgen: deterministic id
  cat > "$STUB_BIN/uuidgen" <<'STUB'
#!/bin/sh
echo "test-uuid-1234"
STUB

  chmod +x "$STUB_BIN"/*

  # -- Fake release tarball -------------------------------------------
  #
  # Contains bin/still (version 0.2.0) and bin/bootstrap.

  FAKE_RELEASE="$TEST_DIR/fake_release"
  mkdir -p "$FAKE_RELEASE/bin"

  cat > "$FAKE_RELEASE/bin/still" <<STUB
#!/bin/sh
echo "still \$*" >> "$STUB_LOG/still.log"
case "\$1" in
  version) echo "0.2.0" ;;
  eval)
    case "\$2" in
      *has_users*) echo "STILL_HAS_USERS=\${STUB_HAS_USERS:-false}" ;;
    esac
    exit 0
    ;;
esac
STUB

  cat > "$FAKE_RELEASE/bin/bootstrap" <<STUB
#!/bin/sh
echo "bootstrap" >> "$STUB_LOG/bootstrap.log"
STUB

  # The real overlay script, not a stub — install.sh delegates the whole
  # tracing toggle to it, so these tests cover both together.
  cp "${BATS_TEST_DIRNAME}/../../rel/overlays/bin/tracing" "$FAKE_RELEASE/bin/tracing"

  chmod +x "$FAKE_RELEASE/bin"/*

  FAKE_TARBALL="$TEST_DIR/still.tar.gz"
  tar -czf "$FAKE_TARBALL" -C "$FAKE_RELEASE" bin

  # -- curl stub (must come after tarball is built) --------------------

  cat > "$STUB_BIN/curl" <<STUB
#!/bin/sh
echo "\$*" >> "$STUB_LOG/curl.log"
_output=""
_prev=""
for arg in "\$@"; do
  if [ "\$_prev" = "-o" ]; then _output="\$arg"; fi
  _prev="\$arg"
done
if [ -n "\$_output" ]; then
  cp "$FAKE_TARBALL" "\$_output"
fi
exit 0
STUB
  chmod +x "$STUB_BIN/curl"

  # -- Environment -----------------------------------------------------

  export PATH="$STUB_BIN:$PATH"
  export STILL_PREFIX="$TEST_DIR/opt/still"
  export STILL_ETC="$TEST_DIR/etc/still"
  export STILL_VAR="$TEST_DIR/var/lib/still"
  export STILL_LOG="$TEST_DIR/var/log/still"
  export STILL_SERVICE="$TEST_DIR/still.service"
  export STILL_TARBALL_URL="https://example.com/still-0.2.0.tar.gz"
  # Pinning STILL_VERSION skips the GitHub API path and gives us a
  # deterministic resolved_target_version for the installed-version file.
  export STILL_VERSION=v0.2.0
  export STILL_SKIP_CADDY_SETUP=1
  export STILL_MODE=standalone
  export STILL_NODE_HOST=127.0.0.1
}

teardown() {
  rm -rf "$TEST_DIR"
}

INSTALL_SH="${BATS_TEST_DIRNAME}/../../scripts/install.sh"

# =====================================================================
# Standalone
# =====================================================================

@test "standalone: env file contains correct vars" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_MODE=standalone$'       "$STILL_ETC/still.env"
  grep -q '^STILL_NODE_HOST=127.0.0.1$'   "$STILL_ETC/still.env"
  grep -q '^DATABASE_PATH=.*still\.db$'    "$STILL_ETC/still.env"
  grep -q '^PORT=4000$'                    "$STILL_ETC/still.env"
  grep -q '^PHX_SERVER=true$'              "$STILL_ETC/still.env"
  # Should NOT contain agent-only vars
  ! grep -q 'STILL_CONTROLLER_NODE' "$STILL_ETC/still.env"
}

@test "standalone: persists STILL_CONTROLLER_DOMAIN to still.env when set" {
  # The runtime reserved-domain guard reads this from the env file the
  # systemd unit sources, so it must survive past install time.
  export STILL_CONTROLLER_DOMAIN=still.example.com
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_CONTROLLER_DOMAIN=still.example.com$' "$STILL_ETC/still.env"
}

@test "standalone: omits STILL_CONTROLLER_DOMAIN from still.env when unset" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  ! grep -q 'STILL_CONTROLLER_DOMAIN' "$STILL_ETC/still.env"
}

@test "standalone: systemd unit has correct paths" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q "Description=Still deployment platform (standalone)" "$STILL_SERVICE"
  grep -q "ExecStart=$STILL_PREFIX/bin/still start"            "$STILL_SERVICE"
  grep -q "ExecStop=$STILL_PREFIX/bin/still stop"              "$STILL_SERVICE"
  grep -q "EnvironmentFile=$STILL_ETC/still.env"               "$STILL_SERVICE"
}

@test "standalone: generates server.id" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ -f "$STILL_ETC/server.id" ]
  [ "$(cat "$STILL_ETC/server.id")" = "test-uuid-1234" ]
}

@test "standalone: generates SECRET_KEY_BASE in still.env.local" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ -f "$STILL_ETC/still.env.local" ]
  grep -q '^SECRET_KEY_BASE=' "$STILL_ETC/still.env.local"
}

@test "standalone: generates RELEASE_COOKIE in still.env.local" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local"
  # Should be a hex string of meaningful length (32 chars from our 16-byte source)
  cookie=$(grep '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local" | cut -d= -f2-)
  [ "${#cookie}" -ge 16 ]
}

@test "two standalone installs in separate prefixes generate different cookies" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  first=$(grep '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local" | cut -d= -f2-)

  # Fresh prefix → fresh install
  other="$TEST_DIR/alt"
  export STILL_PREFIX="$other/opt/still"
  export STILL_ETC="$other/etc/still"
  export STILL_VAR="$other/var/lib/still"
  export STILL_LOG="$other/var/log/still"

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  second=$(grep '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local" | cut -d= -f2-)

  [ -n "$first" ]
  [ -n "$second" ]
  [ "$first" != "$second" ]
}

@test "standalone: calls systemctl daemon-reload and enable" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q 'daemon-reload'        "$STUB_LOG/systemctl.log"
  grep -q 'enable --now still.service' "$STUB_LOG/systemctl.log"
}

@test "standalone: runs migrations" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q 'Still.Release.migrate'            "$STUB_LOG/still.log"
  grep -q 'Still.Release.ensure_local_server' "$STUB_LOG/still.log"
}

@test "standalone: runs bootstrap when no users (non-interactive admin creds)" {
  # No tty under `run`, so supply credentials for the non-interactive path.
  export STILL_ADMIN_EMAIL="admin@example.com"
  export STILL_ADMIN_PASSWORD="password12345"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ -f "$STUB_LOG/bootstrap.log" ]
  grep -q 'bootstrap' "$STUB_LOG/bootstrap.log"
}

@test "standalone: skips bootstrap with guidance when no tty and no admin creds" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG/bootstrap.log" ]
  [[ "$output" == *"No terminal for the first-admin prompt"* ]]
}

@test "standalone: skips bootstrap when users exist" {
  export STUB_HAS_USERS=true
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG/bootstrap.log" ]
}

# =====================================================================
# Agent
# =====================================================================

@test "agent: env file contains STILL_CONTROLLER_NODE" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE="agent-cookie-from-controller"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_MODE=agent$'                        "$STILL_ETC/still.env"
  grep -q '^STILL_CONTROLLER_NODE=still@10.0.0.1$'    "$STILL_ETC/still.env"
}

@test "agent: skips migrations, SECRET_KEY_BASE, and bootstrap" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE="agent-cookie-from-controller"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  # No migrations
  ! grep -q 'Still.Release.migrate' "$STUB_LOG/still.log" 2>/dev/null
  # No SECRET_KEY_BASE
  ! grep -q 'SECRET_KEY_BASE' "$STILL_ETC/still.env.local"
  # No bootstrap
  [ ! -f "$STUB_LOG/bootstrap.log" ]
}

@test "agent: fails without STILL_CONTROLLER_NODE" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE=""
  export RELEASE_COOKIE="agent-cookie"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STILL_CONTROLLER_NODE is required"* ]]
}

@test "agent: fails without RELEASE_COOKIE" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE=""
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELEASE_COOKIE is required"* ]]
}

@test "agent: fails without STILL_SERVER_ID" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE="agent-cookie"
  unset STILL_SERVER_ID
  run sh "$INSTALL_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STILL_SERVER_ID is required"* ]]
  [[ "$output" == *"POST /api/servers"* ]]
}

@test "agent: accepts an existing server.id file in lieu of STILL_SERVER_ID" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE="agent-cookie"
  unset STILL_SERVER_ID
  mkdir -p "$STILL_ETC"
  printf '%s\n' "pre-existing-id" > "$STILL_ETC/server.id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ "$(cat "$STILL_ETC/server.id")" = "pre-existing-id" ]
  grep -q '^STILL_SERVER_ID=pre-existing-id$' "$STILL_ETC/still.env"
}

@test "agent: accepts a bare host and prepends still@" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="192.168.1.70"
  export RELEASE_COOKIE="agent-cookie"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_CONTROLLER_NODE=still@192.168.1.70$' "$STILL_ETC/still.env"
}

@test "agent: accepts a bare DNS host and prepends still@" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="controller.internal"
  export RELEASE_COOKIE="agent-cookie"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_CONTROLLER_NODE=still@controller.internal$' "$STILL_ETC/still.env"
}

@test "agent: leaves the already-prefixed still@host form alone" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@192.168.1.70"
  export RELEASE_COOKIE="agent-cookie"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_CONTROLLER_NODE=still@192.168.1.70$' "$STILL_ETC/still.env"
}

@test "agent: persists the supplied RELEASE_COOKIE to still.env.local" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE="cookie-from-controller-abc123"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^RELEASE_COOKIE=cookie-from-controller-abc123$' "$STILL_ETC/still.env.local"
}

@test "agent: writes STILL_SERVER_ID to server.id" {
  export STILL_MODE=agent
  export STILL_CONTROLLER_NODE="still@10.0.0.1"
  export RELEASE_COOKIE="agent-cookie"
  export STILL_SERVER_ID="registered-agent-id"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ "$(cat "$STILL_ETC/server.id")" = "registered-agent-id" ]
}

# =====================================================================
# STILL_CONTROLLER_TLS validation
# =====================================================================

@test "TLS: defaults to off when not set" {
  # No STILL_CONTROLLER_TLS in the environment → default path; install
  # succeeds because 'off' is a valid value.
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
}

@test "TLS: accepts 'auto'" {
  export STILL_CONTROLLER_TLS=auto
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
}

@test "TLS: accepts 'off'" {
  export STILL_CONTROLLER_TLS=off
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
}

@test "TLS: fails on invalid value" {
  export STILL_CONTROLLER_TLS=whatever
  run sh "$INSTALL_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STILL_CONTROLLER_TLS must be one of"* ]]
}

# =====================================================================
# STILL_TARBALL_URL handling
# =====================================================================

@test "tarball URL: absolute path is auto-prefixed with file://" {
  export STILL_TARBALL_URL="$FAKE_TARBALL"  # absolute path
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q "file://$FAKE_TARBALL" "$STUB_LOG/curl.log"
}

@test "tarball URL: rejects value without a supported scheme" {
  export STILL_TARBALL_URL="ftp://example.com/still.tar.gz"
  run sh "$INSTALL_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STILL_TARBALL_URL must be http://, https://, or file://"* ]]
}

@test "tarball URL: rejects a relative path (neither scheme nor absolute)" {
  export STILL_TARBALL_URL="still.tar.gz"
  run sh "$INSTALL_SH"
  [ "$status" -ne 0 ]
  [[ "$output" == *"STILL_TARBALL_URL must be http://, https://, or file://"* ]]
}

# =====================================================================
# Controller
# =====================================================================

@test "controller: env file and migrations" {
  export STILL_MODE=controller
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_MODE=controller$' "$STILL_ETC/still.env"
  grep -q 'Still.Release.migrate'   "$STUB_LOG/still.log"
}

@test "controller: persists STILL_CONTROLLER_DOMAIN to still.env when set" {
  export STILL_MODE=controller
  export STILL_CONTROLLER_DOMAIN=still.example.com
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_CONTROLLER_DOMAIN=still.example.com$' "$STILL_ETC/still.env"
}

# =====================================================================
# Upgrade
# =====================================================================

@test "re-install: restarts the service when it's already running" {
  # Simulate a running service (marker file in place before the installer
  # runs).
  touch "$STUB_LOG/service_active"

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q 'restart still.service' "$STUB_LOG/systemctl.log"
  # Shouldn't hit the "enable --now" path when the service was already up.
  ! grep -q 'enable --now' "$STUB_LOG/systemctl.log"
}

@test "upgrade: backs up database before migrations" {
  export STILL_UPGRADE=1
  export STILL_ASSUME_YES=1
  # Pre-populate a database file
  mkdir -p "$STILL_VAR"
  echo "fake-db" > "$STILL_VAR/still.db"

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  # A backup file should exist
  ls "$STILL_VAR"/still.db.pre-upgrade-* >/dev/null 2>&1
  [ "$(cat "$STILL_VAR"/still.db.pre-upgrade-*)" = "fake-db" ]
}

@test "upgrade: prints version change" {
  export STILL_UPGRADE=1
  export STILL_ASSUME_YES=1
  # Pre-populate an old installed-version marker so current_version is
  # read from the file (the source of truth) rather than `bin/still`.
  mkdir -p "$STILL_ETC"
  echo "v0.1.0" > "$STILL_ETC/installed-version"

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade: v0.1.0 -> v0.2.0"* ]]
}

@test "upgrade: restarts instead of enable+start" {
  export STILL_UPGRADE=1
  export STILL_ASSUME_YES=1
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q 'restart still.service'    "$STUB_LOG/systemctl.log"
  ! grep -q 'enable --now'           "$STUB_LOG/systemctl.log"
}

@test "upgrade: skips bootstrap" {
  export STILL_UPGRADE=1
  export STILL_ASSUME_YES=1
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ ! -f "$STUB_LOG/bootstrap.log" ]
}

@test "upgrade: shows upgraded banner" {
  export STILL_UPGRADE=1
  export STILL_ASSUME_YES=1
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"upgraded and restarted"* ]]
}

# =====================================================================
# Upgrade detection (auto)
# =====================================================================

@test "auto-upgrade: fresh install writes /etc/still/installed-version" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ -f "$STILL_ETC/installed-version" ]
  [ "$(cat "$STILL_ETC/installed-version")" = "v0.2.0" ]
}

@test "auto-upgrade: re-running with same version exits cleanly" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  # Second run — detection finds installed-version, sees target == current,
  # and bails before touching anything.
  : > "$STUB_LOG/systemctl.log"
  : > "$STUB_LOG/still.log"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already on v0.2.0"* ]]
  # No service touch, no migrations, no extraction work
  [ ! -s "$STUB_LOG/systemctl.log" ]
  ! grep -q 'migrate' "$STUB_LOG/still.log" 2>/dev/null
}

@test "auto-upgrade: detects existing install and skips mode/etc. prompts" {
  # Pre-populate an existing install with mode=controller in env, then re-run
  # with no STILL_MODE in env — detection should source still.env so the
  # controller mode is preserved.
  mkdir -p "$STILL_ETC"
  echo "v0.1.0" > "$STILL_ETC/installed-version"
  cat > "$STILL_ETC/still.env" <<EOF
STILL_MODE=controller
STILL_NODE_HOST=192.168.1.5
STILL_SERVER_ID=preserved-id
EOF
  unset STILL_MODE
  unset STILL_NODE_HOST
  export STILL_ASSUME_YES=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_MODE=controller$'     "$STILL_ETC/still.env"
  grep -q '^STILL_NODE_HOST=192.168.1.5$' "$STILL_ETC/still.env"
  grep -q '^STILL_SERVER_ID=preserved-id$' "$STILL_ETC/still.env"
}

@test "auto-upgrade: newer version upgrades without prompting under ASSUME_YES" {
  mkdir -p "$STILL_ETC"
  echo "v0.1.0" > "$STILL_ETC/installed-version"
  export STILL_ASSUME_YES=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade: v0.1.0 -> v0.2.0"* ]]
  [ "$(cat "$STILL_ETC/installed-version")" = "v0.2.0" ]
}

@test "auto-upgrade: legacy install (server.id + bin/still, no version file)" {
  # Simulate a host installed before this feature: server.id + bin/still
  # exist but installed-version does not.
  mkdir -p "$STILL_ETC" "$STILL_PREFIX/bin"
  echo "legacy-server-id" > "$STILL_ETC/server.id"
  cat > "$STILL_PREFIX/bin/still" <<'STUB'
#!/bin/sh
case "$1" in version) echo "0.1.0" ;; esac
STUB
  chmod +x "$STILL_PREFIX/bin/still"
  export STILL_ASSUME_YES=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade: 0.1.0 -> v0.2.0"* ]]
  # The version file should be written even though it didn't exist before.
  [ "$(cat "$STILL_ETC/installed-version")" = "v0.2.0" ]
}

@test "auto-upgrade: STILL_FORCE_REINSTALL bypasses 'already on' early exit" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  : > "$STUB_LOG/still.log"
  export STILL_FORCE_REINSTALL=1
  export STILL_ASSUME_YES=1
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"Already on"* ]]
  # Migrations re-ran
  grep -q 'Still.Release.migrate' "$STUB_LOG/still.log"
}

# =====================================================================
# Idempotency
# =====================================================================

@test "preserves server.id across runs" {
  sh "$INSTALL_SH"
  first_id=$(cat "$STILL_ETC/server.id")

  sh "$INSTALL_SH"
  second_id=$(cat "$STILL_ETC/server.id")

  [ "$first_id" = "$second_id" ]
}

@test "preserves still.env.local across runs" {
  sh "$INSTALL_SH"
  first_secret=$(grep '^SECRET_KEY_BASE=' "$STILL_ETC/still.env.local")
  first_cookie=$(grep '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local")

  sh "$INSTALL_SH"
  second_secret=$(grep '^SECRET_KEY_BASE=' "$STILL_ETC/still.env.local")
  second_cookie=$(grep '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local")

  [ "$first_secret" = "$second_secret" ]
  [ "$first_cookie" = "$second_cookie" ]
}

@test "controller: install banner shows the cookie and agent install command" {
  export STILL_MODE=controller
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  cookie=$(grep '^RELEASE_COOKIE=' "$STILL_ETC/still.env.local" | cut -d= -f2-)
  [ -n "$cookie" ]

  [[ "$output" == *"To add an agent to this controller"* ]]
  [[ "$output" == *"POST /api/servers"* || "$output" == *"api/servers"* ]]
  [[ "$output" == *"STILL_SERVER_ID=<id-from-step-1>"* ]]
  [[ "$output" == *"$cookie"* ]]
  [[ "$output" == *"STILL_MODE=agent"* ]]
}

# =====================================================================
# Caddy persistence
# =====================================================================

@test "writes the STILL_INGRESS_EDGE_PORT default for non-agent installs" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_INGRESS_EDGE_PORT=8080$' "$STILL_ETC/still.env"
}

@test "writes the STILL_INTERNAL_PORT default for non-agent installs" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  grep -q '^STILL_INTERNAL_PORT=9090$' "$STILL_ETC/still.env"
}

@test "creates the artifacts directory the internal Caddy server roots on" {
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ -d "$STILL_VAR/artifacts" ]
}

# =====================================================================
# Request tracing
# =====================================================================

# The tracing toggle lives inside the Caddy setup block (it writes a
# caddy.service drop-in), which these tests skip by default.
enable_caddy_setup() {
  unset STILL_SKIP_CADDY_SETUP
  export STILL_CADDY_DROPIN="$TEST_DIR/caddy-dropin.conf"
  export STILL_TRACING_DROPIN="$TEST_DIR/caddy-tracing.conf"
}

@test "tracing: off by default — no drop-in, no flag" {
  enable_caddy_setup

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  [ ! -f "$STILL_TRACING_DROPIN" ]
  ! grep -q 'STILL_CADDY_TRACING' "$STILL_ETC/still.env.local"
}

@test "tracing: STILL_CADDY_TRACING=1 writes the exporter drop-in and the flag" {
  enable_caddy_setup
  export STILL_CADDY_TRACING=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  # The three variables Caddy's OTLP exporter reads. http/protobuf is not the
  # SDK default (grpc on :4317 is), so it has to be explicit.
  grep -q '^Environment=OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf$' "$STILL_TRACING_DROPIN"
  grep -q '^Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318$' "$STILL_TRACING_DROPIN"
  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"

  # The flag lives in still.env.local, which is preserved across upgrades —
  # still.env is rewritten every install and would silently drop it.
  grep -q '^STILL_CADDY_TRACING=1$' "$STILL_ETC/still.env.local"

  grep -q 'daemon-reload' "$STUB_LOG/systemctl.log"
}

@test "tracing: a controller install names its Caddy caddy-ingress" {
  # bin/tracing derives the service name from STILL_MODE (which it sees both
  # via the exported env and via the still.env the installer writes first).
  enable_caddy_setup
  export STILL_MODE=controller
  export STILL_CADDY_TRACING=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_SERVICE_NAME=caddy-ingress$' "$STILL_TRACING_DROPIN"
}

@test "tracing: a standalone install names its Caddy caddy" {
  enable_caddy_setup
  export STILL_CADDY_TRACING=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_SERVICE_NAME=caddy$' "$STILL_TRACING_DROPIN"
}

@test "tracing: honors a custom STILL_OTLP_ENDPOINT and persists it" {
  enable_caddy_setup
  export STILL_CADDY_TRACING=1
  export STILL_OTLP_ENDPOINT=http://10.0.0.9:4318

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  grep -q '^Environment=OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.0.9:4318$' "$STILL_TRACING_DROPIN"
  grep -q '^STILL_OTLP_ENDPOINT=http://10.0.0.9:4318$' "$STILL_ETC/still.env.local"
}

# Re-running the installer at the same version exits early by design, so an
# upgrade has to be staged with an older installed-version marker or these
# tests would pass without the second run doing anything.
stage_upgrade_from() {
  echo "$1" > "$STILL_ETC/installed-version"
  export STILL_ASSUME_YES=1
}

@test "tracing: STILL_CADDY_TRACING=0 removes an existing setup" {
  enable_caddy_setup
  export STILL_CADDY_TRACING=1
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ -f "$STILL_TRACING_DROPIN" ]

  stage_upgrade_from v0.1.0
  export STILL_CADDY_TRACING=0
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade: v0.1.0 -> v0.2.0"* ]]

  [ ! -f "$STILL_TRACING_DROPIN" ]
  ! grep -q '^STILL_CADDY_TRACING=1$' "$STILL_ETC/still.env.local"
}

@test "tracing: an upgrade with nothing set leaves tracing on" {
  enable_caddy_setup
  export STILL_CADDY_TRACING=1
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  # Upgrade exactly as an unattended run would: the variable isn't in the
  # environment at all. Tracing must survive — still.env is rewritten on every
  # install, which is why the flag lives in still.env.local.
  stage_upgrade_from v0.1.0
  unset STILL_CADDY_TRACING
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Upgrade: v0.1.0 -> v0.2.0"* ]]

  [ -f "$STILL_TRACING_DROPIN" ]
  grep -q '^STILL_CADDY_TRACING=1$' "$STILL_ETC/still.env.local"
}

@test "tracing: warns instead of silently dropping the flag under STILL_SKIP_CADDY_SETUP" {
  # The suite's default env keeps STILL_SKIP_CADDY_SETUP=1. The tracing apply
  # writes a caddy.service drop-in, which that flag promises not to touch — so
  # the request must be loudly declined, not silently eaten.
  export STILL_TRACING_DROPIN="$TEST_DIR/caddy-tracing.conf"
  export STILL_CADDY_TRACING=1

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  [[ "$output" == *"STILL_CADDY_TRACING is not applied"* ]]
  [ ! -f "$STILL_TRACING_DROPIN" ]
  ! grep -q 'STILL_CADDY_TRACING' "$STILL_ETC/still.env.local"
}

@test "tracing: enabling during an upgrade restarts still.service once, after backup and migrations" {
  # bin/tracing's own still.service restart is suppressed by the installer
  # (STILL_TRACING_SKIP_STILL_RESTART): the new release migrates on boot, so a
  # mid-install restart would make the "pre-upgrade" DB backup post-migration.
  # The installer's unconditional restart at the end is the only one allowed.
  enable_caddy_setup
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  stage_upgrade_from v0.1.0
  export STILL_CADDY_TRACING=1
  : > "$STUB_LOG/systemctl.log"
  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  [ -f "$STILL_TRACING_DROPIN" ]
  [ "$(grep -c 'restart still.service' "$STUB_LOG/systemctl.log")" -eq 1 ]
}

@test "caddy: registers a --resume drop-in so config survives a Caddy restart" {
  # Let the Caddy setup block run (it's skipped by default in these tests).
  unset STILL_SKIP_CADDY_SETUP
  export STILL_CADDY_DROPIN="$TEST_DIR/caddy-dropin.conf"

  run sh "$INSTALL_SH"
  [ "$status" -eq 0 ]

  [ -f "$STILL_CADDY_DROPIN" ]
  grep -q 'run --resume' "$STILL_CADDY_DROPIN"
  # ExecReload is cleared so a Caddyfile reload can't clobber the running config.
  grep -q '^ExecReload=$' "$STILL_CADDY_DROPIN"
  # daemon-reload ran so the next Caddy restart picks up --resume.
  grep -q 'daemon-reload' "$STUB_LOG/systemctl.log"
}
