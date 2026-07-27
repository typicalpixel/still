#!/bin/sh
#
# Still installer. Fetches the latest release from GitHub, unpacks it to
# /opt/still, writes a systemd unit, runs migrations, starts the service,
# and prompts for a first admin user.
#
# Usage:
#
#   curl -fsSL https://deploystill.com/install.sh | sudo sh
#
#   # or, if you have the raw install.sh on disk:
#   sudo sh ./install.sh
#
# Environment overrides (mostly for development):
#
#   STILL_VERSION              tag to install (default: latest release)
#   STILL_TARBALL_URL          explicit URL for the release tarball (overrides GitHub)
#   STILL_MODE                 controller | agent | standalone (default: standalone)
#   STILL_NODE_HOST            hostname/IP to advertise for Erlang distribution
#                              (default: 127.0.0.1, which is fine for standalone)
#   STILL_CONTROLLER_NODE      agents only. The controller's host — a bare IP
#                              or DNS name (e.g. 10.0.0.1). Accepts the full
#                              still@host form too.
#   STILL_SERVER_ID            agents only. Server id returned from registering
#                              this host on the controller (POST /api/servers).
#   RELEASE_COOKIE             agents only. The cookie printed by the
#                              controller's install banner.
#   STILL_PREFIX               install prefix (default: /opt/still)
#   STILL_ETC                  config directory (default: /etc/still)
#   STILL_VAR                  variable state directory (default: /var/lib/still)
#   STILL_CONTROLLER_DOMAIN    public hostname Caddy host-matches the
#                              controller route on (the whole app: dashboard
#                              at / and API at /api). Any shape of DNS name.
#                              Optional; blank falls back to STILL_NODE_HOST so
#                              the route stays host-scoped, and other Hosts hit
#                              the "Still" catch-all page.
#   STILL_CONTROLLER_TLS       auto | off (default: off). `auto` puts Caddy
#                              on :80/:443 with automatic HTTPS via Let's
#                              Encrypt — requires a public domain with DNS
#                              pointing here and ports 80/443 reachable.
#                              `off` listens on STILL_CADDY_HTTP_PORT only;
#                              for operators behind an edge that terminates
#                              TLS (Cloudflare, a cloud LB) or a private
#                              install.
#   STILL_INGRESS_EDGE_PORT    controller only. Port the controller's ingress
#                              Caddy dials on each agent (default: 8080).
#                              Must match the agents' STILL_CADDY_HTTP_PORT.
#   STILL_TRUSTED_PROXIES      comma-separated IPs/CIDRs this node's Caddy
#                              trusts as upstream proxies, so their
#                              X-Forwarded-* headers pass through to apps.
#                              Agents default to the controller's address
#                              (from STILL_CONTROLLER_NODE) when it is an
#                              IP literal; set explicitly otherwise. Empty
#                              string removes a previously set value.
#   STILL_CADDY_TRACING        1 to turn on OpenTelemetry request tracing for
#                              this node's applications, 0 to turn it off.
#                              Unset leaves whatever's already configured
#                              alone, so an upgrade never silently changes it.
#                              On a fresh interactive install the installer
#                              offers this only when it finds an OTLP
#                              collector listening locally. Equivalent to
#                              running `bin/tracing on|off` afterwards. Not
#                              applied under STILL_SKIP_CADDY_SETUP=1 (it
#                              writes a caddy.service drop-in) — the installer
#                              warns and leaves it to you.
#   STILL_OTLP_ENDPOINT        collector the node's Caddy exports spans to
#                              (default http://127.0.0.1:4318). Base URL —
#                              /v1/traces is appended by the exporter.
#   STILL_SKIP_CADDY_SETUP     set to 1 if you manage Caddy yourself: the
#                              installer then won't reconcile Caddy's base
#                              config or touch caddy.service. Ensure your
#                              Caddy runs with `--resume` so Still's
#                              admin-API config survives a restart.
#   STILL_UPGRADE              set to 1 to force upgrade mode. Auto-detected
#                              when an existing install is present (via
#                              /etc/still/installed-version, or
#                              /etc/still/server.id + $STILL_PREFIX/bin/still),
#                              so you don't normally need to set this. Use it
#                              for repair scenarios where the detection
#                              signals are missing.
#   STILL_ASSUME_YES           set to 1 to skip the upgrade confirmation
#                              prompt. Also implied by a non-tty stdin
#                              (curl ... | sudo sh in CI).
#   STILL_FORCE_REINSTALL      set to 1 to re-run the install even when the
#                              target version equals the currently installed
#                              version.
#
# The installer is idempotent — re-running upgrades in place. Mode,
# controller node, domain, TLS, server id, and cookies are read from
# /etc/still/still.env and /etc/still/still.env.local on upgrade, so the
# operator runs the same one-liner and only confirms the version jump.
#
# When a terminal is available and required env vars are not pre-set, the
# installer prompts interactively. If all vars are set (or stdin is not a
# terminal), it runs fully non-interactively.

set -eu

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

say() { printf "==> %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# Asserts $1 (semver-shaped) is >= $2. Uses `sort -V` so 2.10 > 2.9 sorts
# correctly. Dies with a clear error otherwise.
need_version() {
  found="$1"; required="$2"; tool="$3"
  if [ "$(printf '%s\n%s\n' "$required" "$found" | sort -V | head -n1)" != "$required" ]; then
    die "$tool >= $required required (found $found)"
  fi
}

can_prompt() { ( exec < /dev/tty ) 2>/dev/null; }

# -----------------------------------------------------------------------------
# Hard requirements — checked before prompts so we fail fast on missing tooling
# instead of asking five questions and then choking on a missing binary.
# -----------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "must be run as root (try: curl ... | sudo sh)"

case "$(uname -s)" in
  Linux) : ;;
  *) die "Still only supports Linux; detected $(uname -s)" ;;
esac

need_cmd curl
need_cmd tar
need_cmd systemctl
need_cmd caddy

# Caddy 2.9 added the per-host metrics field that Still relies on for
# per-application request counts. Older Caddys reject the config at load
# time with "unknown field per_host"; fail here so the operator sees the
# real cause instead of a cryptic config-load error mid-install.
caddy_version="$(caddy version | head -n1 | sed -E 's/^v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
[ -n "$caddy_version" ] || die "could not parse Caddy version from 'caddy version' output"
need_version "$caddy_version" "2.9.0" "Caddy"

# -----------------------------------------------------------------------------
# Upgrade detection
# -----------------------------------------------------------------------------
#
# Re-running install.sh on a host that already has Still should upgrade in
# place — same one-liner, no env-var toggle. Either signal flips the script
# into upgrade mode and the existing env files become the source of truth
# for mode / controller / domain / cookie / server id / TLS, so no other
# prompts fire.
#
# Both signals are checked: installs from before this feature landed won't
# have installed-version yet, but they will have server.id + bin/still.

STILL_ETC="${STILL_ETC:-/etc/still}"
STILL_PREFIX="${STILL_PREFIX:-/opt/still}"

if [ -f "$STILL_ETC/installed-version" ] \
   || { [ -f "$STILL_ETC/server.id" ] && [ -x "$STILL_PREFIX/bin/still" ]; }; then
  STILL_UPGRADE=1
fi

# Captured before the upgrade path sources still.env.local below: the stored
# STILL_CADDY_TRACING would otherwise shadow a value the operator passed on
# this run, making it impossible to turn tracing off from the command line.
# Empty means "leave tracing however it's already configured".
STILL_CADDY_TRACING_REQUESTED="${STILL_CADDY_TRACING:-}"

if [ "${STILL_UPGRADE:-}" = "1" ]; then
  set -a
  # shellcheck disable=SC1090
  [ -f "$STILL_ETC/still.env" ] && . "$STILL_ETC/still.env"
  # shellcheck disable=SC1090
  [ -f "$STILL_ETC/still.env.local" ] && . "$STILL_ETC/still.env.local"
  set +a
fi

# -----------------------------------------------------------------------------
# Interactive setup
# -----------------------------------------------------------------------------
#
# Each prompt checks its env var first. If all required vars are pre-set, no
# prompts fire — preserving the scripted path for CI / Ansible / Terraform.
# Prompts read from /dev/tty so they work even when the script itself is piped
# (curl ... | sudo sh).

# Mode
if [ -z "${STILL_MODE+x}" ] && can_prompt; then
  cat > /dev/tty <<'PROMPT'

How will this server be used?

  [1] Standalone  — single server, runs everything (default)
  [2] Controller  — multi-server fleet, this is the control plane
  [3] Agent       — multi-server fleet, this runs applications

PROMPT
  printf "Choose [1/2/3]: " > /dev/tty
  read -r _mode_choice < /dev/tty
  case "$_mode_choice" in
    2) STILL_MODE=controller ;;
    3) STILL_MODE=agent ;;
    *) STILL_MODE=standalone ;;
  esac
fi

# Agent: controller address
if [ "${STILL_MODE:-}" = "agent" ] && [ -z "${STILL_CONTROLLER_NODE+x}" ] && can_prompt; then
  printf "\nController host (IP or DNS name, e.g. 10.0.0.1): " > /dev/tty
  read -r STILL_CONTROLLER_NODE < /dev/tty
fi

# Accept bare host or the full still@host form. The release name is
# always `still`, so everything else is implementation detail.
case "${STILL_CONTROLLER_NODE:-}" in
  still@*) : ;;
  "")      : ;;
  *)       STILL_CONTROLLER_NODE="still@$STILL_CONTROLLER_NODE" ;;
esac

# Agent: Erlang cookie (generated on the controller at install time)
if [ "${STILL_MODE:-}" = "agent" ] && [ -z "${RELEASE_COOKIE+x}" ] && can_prompt; then
  printf "\nErlang cookie (from the controller's install output): " > /dev/tty
  read -r RELEASE_COOKIE < /dev/tty
fi

# Agent: server id. The controller won't surface this agent in /api/servers
# until a row exists at the matching id — so the operator registers the
# server on the controller first (POST /api/servers) and pastes the id
# back here. Only prompt when there's no existing /etc/still/server.id.
if [ "${STILL_MODE:-}" = "agent" ] \
  && [ -z "${STILL_SERVER_ID+x}" ] \
  && [ ! -f "${STILL_ETC:-/etc/still}/server.id" ] \
  && can_prompt; then
  cat > /dev/tty <<'PROMPT'

Server id — register this agent on the controller first:

  curl -X POST https://<controller>/api/servers \
    -H 'Authorization: Bearer <api-key>' \
    -H 'Content-Type: application/json' \
    -d '{"name":"<name>","host":"<this-agent-host>","roles":["application"]}'

Paste the `id` field from the response below.

PROMPT
  printf "Server id: " > /dev/tty
  read -r STILL_SERVER_ID < /dev/tty
fi

# Controller / Standalone: dashboard domain. Skipped on upgrade — the value
# (set or deliberately blank) already comes from the sourced still.env, so we
# don't re-ask a question the operator answered at install time.
if [ "${STILL_MODE:-}" != "agent" ] && [ "${STILL_UPGRADE:-}" != "1" ] && [ -z "${STILL_CONTROLLER_DOMAIN+x}" ] && can_prompt; then
  printf "\nDomain — the public hostname you'll reach Still on, e.g.\n" > /dev/tty
  printf "still.example.com. It serves the dashboard at / and the API\n" > /dev/tty
  printf "under /api, so this is also the host your deploys (GitHub\n" > /dev/tty
  printf "Actions, CLI) call. Point its DNS at this server. Leave blank\n" > /dev/tty
  printf "for a private install reached by raw IP (Caddy host-scopes to\n" > /dev/tty
  printf "this machine's address); behind Cloudflare or a cloud LB, set\n" > /dev/tty
  printf "the hostname that edge forwards.\n" > /dev/tty
  printf "Domain: " > /dev/tty
  read -r STILL_CONTROLLER_DOMAIN < /dev/tty
fi

# Controller / Standalone: TLS mode — explicitly chosen, not inferred. The
# domain could be terminated by Caddy itself, or by an edge in front
# (Cloudflare, a cloud LB); the operator picks.
if [ "${STILL_MODE:-}" != "agent" ] && [ "${STILL_UPGRADE:-}" != "1" ] && [ -z "${STILL_CONTROLLER_TLS+x}" ] && can_prompt; then
  printf "\nTLS — does THIS server terminate HTTPS for that domain?\n" > /dev/tty
  printf "  auto — yes: Caddy listens on :80/:443 and gets a Let's Encrypt cert\n" > /dev/tty
  printf "         (needs the domain's DNS pointed here and :80/:443 reachable)\n" > /dev/tty
  printf "  off  — no: an edge in front terminates TLS (Cloudflare, a load\n" > /dev/tty
  printf "         balancer), or it's a private install on a trusted network\n" > /dev/tty
  printf "[off]: " > /dev/tty
  read -r STILL_CONTROLLER_TLS < /dev/tty
  STILL_CONTROLLER_TLS="${STILL_CONTROLLER_TLS:-off}"
fi

# All modes: request tracing. Only offered when something is already listening
# on the OTLP endpoint — an operator with no collector shouldn't have to answer
# a question about OpenTelemetry to install Still. Skipped on upgrade; the
# answer lives in still.env.local and `bin/tracing on|off` changes it later.
if [ "${STILL_UPGRADE:-}" != "1" ] && [ -z "${STILL_CADDY_TRACING+x}" ] \
  && [ -z "${STILL_SKIP_CADDY_SETUP:-}" ] && can_prompt \
  && curl -sS -m 2 --noproxy '*' -o /dev/null "${STILL_OTLP_ENDPOINT:-http://127.0.0.1:4318}/v1/traces" 2>/dev/null; then
  printf "\nRequest tracing — found an OTLP collector at %s.\n" \
    "${STILL_OTLP_ENDPOINT:-http://127.0.0.1:4318}" > /dev/tty
  printf "Caddy can emit one span per proxied request, named after the\n" > /dev/tty
  printf "application, and pass the trace context to it so the app's own\n" > /dev/tty
  printf "traces nest underneath. Still's dashboard is never traced.\n" > /dev/tty
  printf "Enable request tracing? [y/N]: " > /dev/tty
  read -r _tracing_answer < /dev/tty

  case "$_tracing_answer" in
    y | Y | yes | YES) STILL_CADDY_TRACING_REQUESTED=1 ;;
    *) STILL_CADDY_TRACING_REQUESTED=0 ;;
  esac
fi

# All modes: node host
if [ -z "${STILL_NODE_HOST+x}" ] && can_prompt; then
  _detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  _detected_ip="${_detected_ip:-127.0.0.1}"
  printf "\nNode host — the address other Still nodes use to reach this machine.\n" > /dev/tty
  printf "This is Still's internal control plane (controller <-> agents), NOT how\n" > /dev/tty
  printf "users or your API reach you. On a standalone server nothing connects to\n" > /dev/tty
  printf "it, so the default is fine. It only matters once you add remote agents,\n" > /dev/tty
  printf "where it must be an address those agents can route to.\n" > /dev/tty
  # List the routable addresses so the operator picks the right interface
  # instead of blindly accepting the first one (e.g. a NAT/bridge IP).
  _addrs=$(ip -o -4 addr show scope global 2>/dev/null \
    | awk '{sub(/\/.*/, "", $4); printf "  %-12s %s\n", $2, $4}')
  if [ -n "$_addrs" ]; then
    printf "Addresses on this machine:\n%s\n" "$_addrs" > /dev/tty
  fi
  printf "Node host [%s]: " "$_detected_ip" > /dev/tty
  read -r STILL_NODE_HOST < /dev/tty
  STILL_NODE_HOST="${STILL_NODE_HOST:-$_detected_ip}"
fi

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

STILL_REPO="${STILL_REPO:-typicalpixel/still}"
STILL_VERSION="${STILL_VERSION:-latest}"
STILL_MODE="${STILL_MODE:-standalone}"
STILL_NODE_HOST="${STILL_NODE_HOST:-127.0.0.1}"
STILL_PREFIX="${STILL_PREFIX:-/opt/still}"
STILL_ETC="${STILL_ETC:-/etc/still}"
STILL_VAR="${STILL_VAR:-/var/lib/still}"
STILL_LOG="${STILL_LOG:-/var/log/still}"
STILL_SERVICE="${STILL_SERVICE:-/etc/systemd/system/still.service}"

# -----------------------------------------------------------------------------
# Value validation — hard requirements already checked above; this block
# validates the *values* provided via env or prompt.
# -----------------------------------------------------------------------------

case "$STILL_MODE" in
  controller|agent|standalone) : ;;
  *) die "STILL_MODE must be one of: controller, agent, standalone" ;;
esac

if [ "$STILL_MODE" = "agent" ]; then
  [ -n "${STILL_CONTROLLER_NODE:-}" ] || \
    die "STILL_CONTROLLER_NODE is required when STILL_MODE=agent"
  [ -n "${RELEASE_COOKIE:-}" ] || \
    die "RELEASE_COOKIE is required when STILL_MODE=agent (get it from the controller's install output)"

  # Require a pre-registered server id. Without it the agent connects but
  # /api/servers stays empty because no row matches — confusing failure
  # mode we'd rather catch here.
  if [ -z "${STILL_SERVER_ID:-}" ] && [ ! -f "${STILL_ETC:-/etc/still}/server.id" ]; then
    die "STILL_SERVER_ID is required when STILL_MODE=agent — register this server on the controller first (POST /api/servers) and pass the returned id as STILL_SERVER_ID"
  fi
fi

STILL_CONTROLLER_TLS="${STILL_CONTROLLER_TLS:-off}"
case "$STILL_CONTROLLER_TLS" in
  auto|off) : ;;
  *) die "STILL_CONTROLLER_TLS must be one of: auto, off" ;;
esac

# -----------------------------------------------------------------------------
# Resolve release tarball URL
# -----------------------------------------------------------------------------

tag_name=""
if [ -n "${STILL_TARBALL_URL:-}" ]; then
  tarball_url="$STILL_TARBALL_URL"
  # Absolute paths get file:// so curl accepts them.
  case "$tarball_url" in
    /*) tarball_url="file://$tarball_url" ;;
  esac
  case "$tarball_url" in
    http://*|https://*|file://*) : ;;
    *) die "STILL_TARBALL_URL must be http://, https://, or file:// (got: $STILL_TARBALL_URL)" ;;
  esac
  say "Using override tarball URL: $tarball_url"
else
  if [ "$STILL_VERSION" = "latest" ]; then
    api_url="https://api.github.com/repos/${STILL_REPO}/releases/latest"
  else
    api_url="https://api.github.com/repos/${STILL_REPO}/releases/tags/${STILL_VERSION}"
  fi

  say "Resolving Still release from $api_url"
  api_response=$(curl -fsSL "$api_url") || die "failed to fetch release metadata"

  tarball_url=$(printf '%s' "$api_response" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*still-[^"]*\.tar\.gz"' \
    | head -n1 \
    | sed -E 's/.*"([^"]+)"$/\1/')
  tag_name=$(printf '%s' "$api_response" \
    | grep -oE '"tag_name":[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed -E 's/.*"([^"]+)"$/\1/')

  [ -n "$tarball_url" ] || die "no tarball asset found in release"
fi

# Canonical tag string for this install. Used by the upgrade prompt and
# written to /etc/still/installed-version at the end of a successful run.
# When STILL_VERSION is "latest" we prefer tag_name (resolved from the
# release JSON) so the installed-version file records a real tag rather
# than the literal string "latest".
if [ "$STILL_VERSION" = "latest" ] && [ -n "$tag_name" ]; then
  resolved_target_version="$tag_name"
else
  resolved_target_version="$STILL_VERSION"
fi

# -----------------------------------------------------------------------------
# Upgrade compare + prompt
# -----------------------------------------------------------------------------

current_version=""

if [ "${STILL_UPGRADE:-}" = "1" ]; then
  if [ -f "$STILL_ETC/installed-version" ]; then
    current_version=$(cat "$STILL_ETC/installed-version")
  elif [ -x "$STILL_PREFIX/bin/still" ]; then
    # Legacy pre-feature install — bin/still is on disk but the tag was
    # never persisted. The version file gets written at the end of this
    # run, so this branch only fires once.
    current_version=$("$STILL_PREFIX/bin/still" version 2>/dev/null || echo "unknown")
  else
    current_version="unknown"
  fi

  if [ "$current_version" = "$resolved_target_version" ] \
     && [ -z "${STILL_FORCE_REINSTALL:-}" ]; then
    say "Already on $current_version; nothing to do."
    exit 0
  fi

  if [ "${STILL_ASSUME_YES:-}" != "1" ] && can_prompt; then
    printf "Upgrade Still from %s to %s? [Y/n]: " \
      "$current_version" "$resolved_target_version" > /dev/tty
    read -r _answer < /dev/tty
    case "$_answer" in
      ""|y|Y|yes|YES) : ;;
      *) die "Upgrade cancelled" ;;
    esac
  fi
fi

# -----------------------------------------------------------------------------
# Directories
# -----------------------------------------------------------------------------

say "Creating directories"
# `artifacts` roots the internal Caddy file_server (build artifacts agents
# pull); without it the first cross-node fetch 404s.
mkdir -p "$STILL_PREFIX" "$STILL_ETC" "$STILL_VAR/applications" "$STILL_VAR/artifacts" "$STILL_LOG"

# -----------------------------------------------------------------------------
# Server identity (agent or standalone; a fresh UUID per host, preserved on upgrade)
# -----------------------------------------------------------------------------

server_id_file="$STILL_ETC/server.id"

if [ ! -f "$server_id_file" ]; then
  if [ -n "${STILL_SERVER_ID:-}" ]; then
    say "Using STILL_SERVER_ID for server identity at $server_id_file"
    printf '%s\n' "$STILL_SERVER_ID" > "$server_id_file"
  elif command -v uuidgen >/dev/null 2>&1; then
    say "Generating server identity at $server_id_file"
    uuidgen > "$server_id_file"
  else
    say "Generating server identity at $server_id_file"
    # Fallback: /proc/sys/kernel/random/uuid is present on every Linux
    cat /proc/sys/kernel/random/uuid > "$server_id_file"
  fi
  chmod 0600 "$server_id_file"
fi

server_id=$(cat "$server_id_file")

# -----------------------------------------------------------------------------
# Download and extract release
# -----------------------------------------------------------------------------

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

say "Downloading $tarball_url"
curl -fsSL "$tarball_url" -o "$tmp_dir/still.tar.gz"

say "Extracting to $STILL_PREFIX"
tar -xzf "$tmp_dir/still.tar.gz" -C "$STILL_PREFIX"

if [ "${STILL_UPGRADE:-}" = "1" ]; then
  say "Upgrade: $current_version -> $resolved_target_version"
fi

# -----------------------------------------------------------------------------
# Environment file
# -----------------------------------------------------------------------------

env_file="$STILL_ETC/still.env"

say "Writing $env_file"
cat > "$env_file" <<EOF
# Still runtime configuration. Rewritten by scripts/install.sh on every
# install/upgrade, but your edits to secret keys / ports / overrides
# should go in /etc/still/still.env.local if you want them preserved.
STILL_MODE=$STILL_MODE
STILL_NODE_HOST=$STILL_NODE_HOST
STILL_SERVER_ID=$server_id
DATABASE_PATH=$STILL_VAR/still.db
PORT=4000
PHX_SERVER=true
EOF

if [ "$STILL_MODE" = "agent" ]; then
  echo "STILL_CONTROLLER_NODE=$STILL_CONTROLLER_NODE" >> "$env_file"
else
  # Controller / standalone: runtime.exs reads these to build the
  # Phoenix Endpoint's external URL. Mirror of the values passed to
  # CaddyBootstrap below.
  [ -n "${STILL_CONTROLLER_DOMAIN:-}" ] && \
    echo "STILL_CONTROLLER_DOMAIN=$STILL_CONTROLLER_DOMAIN" >> "$env_file"
  echo "STILL_CONTROLLER_TLS=${STILL_CONTROLLER_TLS}" >> "$env_file"
  echo "STILL_CADDY_HTTP_PORT=${STILL_CADDY_HTTP_PORT:-8080}" >> "$env_file"
  # Port the controller's ingress dials on each agent. Defaults to 8080 and
  # must match the agents' STILL_CADDY_HTTP_PORT; persisted so a pre-set
  # value survives and a fleet on a non-default port still routes.
  echo "STILL_INGRESS_EDGE_PORT=${STILL_INGRESS_EDGE_PORT:-8080}" >> "$env_file"
  # Port the internal Caddy serves build artifacts on, and that runtime.exs
  # advertises to agents. Persisted so a custom port survives upgrades and the
  # advertised artifact URL matches what Caddy actually listens on.
  echo "STILL_INTERNAL_PORT=${STILL_INTERNAL_PORT:-9090}" >> "$env_file"
fi

chmod 0640 "$env_file"

# -----------------------------------------------------------------------------
# Secrets (still.env.local) — generated once, preserved across upgrades.
# -----------------------------------------------------------------------------
#
# SECRET_KEY_BASE signs session cookies and must be ≥ 64 bytes. We generate
# it on first install and never overwrite it, so existing sessions survive
# upgrades. Operators who want to rotate it can delete the line and re-run
# the installer, or edit still.env.local by hand.

env_local="$STILL_ETC/still.env.local"

if [ "$STILL_MODE" != "agent" ] && ! grep -q '^SECRET_KEY_BASE=' "$env_local" 2>/dev/null; then
  say "Generating SECRET_KEY_BASE in $env_local"
  secret=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
  touch "$env_local"
  chmod 0600 "$env_local"
  printf 'SECRET_KEY_BASE=%s\n' "$secret" >> "$env_local"
fi

# Erlang distribution cookie. Controller / standalone generate a fresh
# one on first install; agents supply it via env var or prompt (checked
# in preflight above). Written to still.env.local once and preserved
# across upgrades — rotating invalidates every connected agent.
if ! grep -q '^RELEASE_COOKIE=' "$env_local" 2>/dev/null; then
  if [ "$STILL_MODE" != "agent" ]; then
    say "Generating RELEASE_COOKIE in $env_local"
    RELEASE_COOKIE=$(head -c 16 /dev/urandom | od -An -vtx1 | tr -d ' \n')
  else
    say "Saving RELEASE_COOKIE to $env_local"
  fi
  touch "$env_local"
  chmod 0600 "$env_local"
  printf 'RELEASE_COOKIE=%s\n' "$RELEASE_COOKIE" >> "$env_local"
fi

# -----------------------------------------------------------------------------
# Source env files for subsequent `still eval` invocations.
#
# Every `still eval` runs config/runtime.exs, which reads a handful of
# required env vars (DATABASE_PATH, SECRET_KEY_BASE, STILL_MODE,
# STILL_SERVER_ID, etc.) and raises on any that are missing. Sourcing
# both env files once here — after they've been written above — means
# every subsequent eval inherits the real runtime config and we don't
# need ad-hoc stubs per call.
# -----------------------------------------------------------------------------

set -a
# shellcheck disable=SC1090
. "$env_file"
# still.env.local is optional on agent installs (no SECRET_KEY_BASE written).
# shellcheck disable=SC1090
[ -f "$env_local" ] && . "$env_local"
set +a

# -----------------------------------------------------------------------------
# systemd unit
# -----------------------------------------------------------------------------

say "Writing $STILL_SERVICE"
cat > "$STILL_SERVICE" <<EOF
[Unit]
Description=Still deployment platform ($STILL_MODE)
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=$env_file
EnvironmentFile=-$STILL_ETC/still.env.local
ExecStart=$STILL_PREFIX/bin/still start
ExecStop=$STILL_PREFIX/bin/still stop
Restart=on-failure
RestartSec=5
TimeoutStopSec=120
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# -----------------------------------------------------------------------------
# Caddy base configuration
# -----------------------------------------------------------------------------
#
# Still's deploy code expects a Caddy HTTP server named "still" to exist at
# the admin API's /config path — it writes per-app routes into that server's
# `routes` array at deploy time. We also need base routes so API clients and
# the dashboard reach Still's Phoenix endpoint through the same Caddy:
#
#   @id still_controller → host-matched, all paths → localhost:$PORT
#   @id still_catchall   → any unmatched host       → 200 "Still" page
#
# Agent nodes get no controller route (nothing listens on $PORT there, and a
# route host-matched to the agent's own address would swallow the ingress
# health probes); a stale one from an earlier install is dropped on reconcile.
#
# The JSON shape is built by Still.CaddyBootstrap so it lives in one place
# and can be unit-tested. We shell out to `still eval` because the release
# is already on disk by the time this block runs.
#
# STILL_CONTROLLER_DOMAIN sets the host matcher on the controller route — any
# shape of DNS name. Left blank, it falls back to STILL_NODE_HOST so the
# route is still host-scoped and stray Host headers hit the catch-all page;
# behind an edge that forwards a public hostname (Cloudflare, a cloud LB),
# set it to that hostname.
#
# STILL_CONTROLLER_TLS decides the listener and TLS handling independently:
#   auto → listens on :80 + :443, Caddy handles ACME for the controller
#          domain and per-app domains. Requires a public domain + reachable
#          ports 80/443.
#   off  → listens on $STILL_CADDY_HTTP_PORT only. An edge in front handles
#          TLS (Cloudflare, a cloud LB), or it's a private install.
#
# Reconciliation is idempotent on every install:
#
#   * Still.CaddyBootstrap.rebuild replaces the controller route and listen
#     array in place and re-pins the catch-all last, preserving any per-app
#     routes already in the array, then pushes the whole config via /load.
#
# If you're installing Still alongside an existing Caddy setup and want to
# manage the "still" server yourself, set STILL_SKIP_CADDY_SETUP=1.

STILL_CADDY_HTTP_PORT="${STILL_CADDY_HTTP_PORT:-8080}"
STILL_CADDY_ADMIN_URL="${STILL_CADDY_ADMIN_URL:-http://localhost:2019}"
STILL_BACKEND="localhost:${PORT:-4000}"
STILL_CONTROLLER_DOMAIN="${STILL_CONTROLLER_DOMAIN:-}"

# Elixir literals for the reconcile keyword list:
#   domain_literal  → "still.example.com" or nil
#   tls_literal     → :auto or :off
if [ -n "$STILL_CONTROLLER_DOMAIN" ]; then
  domain_literal="\"$STILL_CONTROLLER_DOMAIN\""
else
  domain_literal="nil"
fi
tls_literal=":${STILL_CONTROLLER_TLS}"

# Trusted upstream proxies. Agents default to the controller's address so
# X-Forwarded-* headers survive the ingress hop; derived only when
# STILL_CONTROLLER_NODE is an IP literal — set STILL_TRUSTED_PROXIES
# explicitly otherwise. Unset → leave existing config alone (nil);
# empty → remove (Elixir []).
if [ -z "${STILL_TRUSTED_PROXIES+x}" ] && [ "$STILL_MODE" = "agent" ]; then
  _controller_host="${STILL_CONTROLLER_NODE#*@}"
  case "$_controller_host" in
    *[!0-9.]*) : ;;
    *) STILL_TRUSTED_PROXIES="$_controller_host/32" ;;
  esac
fi

if [ -z "${STILL_TRUSTED_PROXIES+x}" ]; then
  proxies_literal="nil"
elif [ -z "$STILL_TRUSTED_PROXIES" ]; then
  proxies_literal="[]"
else
  proxies_literal="[\"$(printf '%s' "$STILL_TRUSTED_PROXIES" | sed 's/,/", "/g')\"]"
fi

if [ -z "${STILL_SKIP_CADDY_SETUP:-}" ]; then
  say "Reconciling Caddy base config (set STILL_SKIP_CADDY_SETUP=1 to skip)"

  if ! curl -fsS "$STILL_CADDY_ADMIN_URL/config/" >/dev/null 2>&1; then
    die "Caddy admin API at $STILL_CADDY_ADMIN_URL is not reachable; is Caddy running?"
  fi

  # Still.CaddyBootstrap.reconcile/1 reads the current Caddy config,
  # rebuilds the "still" server's listen + system routes, preserves any
  # per-application routes that were added at deploy time, and pushes the
  # whole thing back via load_config. Single admin-API round trip.
  "$STILL_PREFIX/bin/still" eval "
    Still.Release.caddy_reconcile(
      mode: :$STILL_MODE,
      backend: \"$STILL_BACKEND\",
      http_port: $STILL_CADDY_HTTP_PORT,
      controller_domain: $domain_literal,
      fallback_host: \"$STILL_NODE_HOST\",
      tls_mode: $tls_literal,
      trusted_proxies: $proxies_literal,
      internal_port: ${STILL_INTERNAL_PORT:-9090},
      artifacts_dir: \"$STILL_VAR/artifacts\"
    )
  " || die "failed to reconcile Caddy base config"

  # Persist Still's config across Caddy restarts, independent of Still
  # itself. Caddy autosaves every admin-API config load; `--resume` makes
  # caddy.service restore that autosave on reboot/upgrade/crash instead of
  # the stock Caddyfile — so deployed apps keep serving even when Still is
  # stopped or dead. We only register the drop-in (the next Caddy restart
  # picks it up); we don't restart Caddy now, since its config is already
  # live this session and a restart would blip running apps. `--config` is
  # kept as a first-boot seed — rebuild preserves any non-Still servers it
  # finds, except the package's default welcome page when it sits on a port
  # the still server needs (e.g. :80 under tls_mode=auto), which it evicts.
  caddy_dropin="${STILL_CADDY_DROPIN:-/etc/systemd/system/caddy.service.d/still.conf}"
  if systemctl cat caddy.service >/dev/null 2>&1; then
    caddy_bin="$(command -v caddy)"
    if [ -f /etc/caddy/Caddyfile ]; then
      caddy_exec="$caddy_bin run --resume --config /etc/caddy/Caddyfile"
    else
      caddy_exec="$caddy_bin run --resume"
    fi
    say "Configuring caddy.service to resume Still's config on restart"
    mkdir -p "$(dirname "$caddy_dropin")"
    cat > "$caddy_dropin" <<EOF
# Managed by Still's installer. Caddy autosaves every admin-API config load;
# --resume restores that autosaved config on restart so deployed apps keep
# serving across reboots and upgrades even when Still isn't running. Config
# is managed through the admin API, so ExecReload is cleared to stop a
# Caddyfile reload from clobbering the running config.
[Service]
ExecStart=
ExecStart=$caddy_exec
ExecReload=
EOF
    systemctl daemon-reload
  else
    warn "No caddy.service unit found — ensure your Caddy starts with 'caddy run --resume' so Still's routes survive a Caddy restart."
  fi

  # Request tracing. Unset means "leave it as it is", so an upgrade never
  # flips it either way. bin/tracing owns both halves (the STILL_CADDY_TRACING
  # flag in still.env.local and caddy.service's exporter drop-in) so the
  # installer and a later `bin/tracing on` can't drift apart.
  # SKIP_STILL_RESTART: the installer restarts still.service itself at the end
  # of the run, after the pre-upgrade DB backup and migrations — a restart here
  # would boot the new release (which migrates on boot) ahead of both.
  case "$STILL_CADDY_TRACING_REQUESTED" in
    1 | true)
      say "Enabling request tracing (bin/tracing on)"
      STILL_TRACING_SKIP_STILL_RESTART=1 "$STILL_PREFIX/bin/tracing" on ||
        warn "request tracing setup failed — finish with: $STILL_PREFIX/bin/tracing on"
      ;;
    0 | false)
      STILL_TRACING_SKIP_STILL_RESTART=1 "$STILL_PREFIX/bin/tracing" off ||
        warn "request tracing teardown failed — finish with: $STILL_PREFIX/bin/tracing off"
      ;;
  esac
else
  say "Skipping Caddy base config (STILL_SKIP_CADDY_SETUP is set)"

  if [ -n "$STILL_CADDY_TRACING_REQUESTED" ]; then
    warn "STILL_CADDY_TRACING is not applied when STILL_SKIP_CADDY_SETUP is set — it writes a caddy.service drop-in. Run $STILL_PREFIX/bin/tracing on|off yourself if you want that."
  fi
fi

# -----------------------------------------------------------------------------
# Migrations + local server registration (controller / standalone only)
# -----------------------------------------------------------------------------

if [ "$STILL_MODE" != "agent" ]; then
  # Env files were sourced earlier, so the release eval below sees
  # DATABASE_PATH / SECRET_KEY_BASE / STILL_* without any per-call stubs.

  # Upgrade: back up database before migrations
  if [ "${STILL_UPGRADE:-}" = "1" ]; then
    _db_path="$STILL_VAR/still.db"
    if [ -f "$_db_path" ]; then
      _backup="$_db_path.pre-upgrade-$(date +%s)"
      say "Backing up database to $_backup"
      cp "$_db_path" "$_backup"
    fi
  fi

  say "Running database migrations"
  "$STILL_PREFIX/bin/still" eval 'Still.Release.migrate()'

  say "Registering local server in the fleet"
  "$STILL_PREFIX/bin/still" eval 'Still.Release.ensure_local_server()'
fi

# -----------------------------------------------------------------------------
# Start the service
# -----------------------------------------------------------------------------

if [ "${STILL_UPGRADE:-}" = "1" ]; then
  say "Restarting still.service"
  systemctl restart still.service
elif systemctl is-active --quiet still.service; then
  say "still.service is already running; restarting to pick up config changes"
  systemctl restart still.service
else
  say "Enabling and starting still.service"
  systemctl enable --now still.service
fi

sleep 2
if ! systemctl is-active --quiet still.service; then
  systemctl status still.service --no-pager || true
  die "still.service failed to start"
fi

# -----------------------------------------------------------------------------
# Bootstrap first admin user (controller / standalone only, fresh install only)
# -----------------------------------------------------------------------------

if [ "$STILL_MODE" != "agent" ] && [ "${STILL_UPGRADE:-}" != "1" ]; then
  # env files already sourced above — has_users check inherits the
  # runtime config from the parent shell.
  # Print a sentinel and grep for it rather than trusting the last output
  # line: `still eval` boots the release and may emit logger/SASL lines
  # after the result, and a bare `tail -n1` would then silently skip
  # bootstrapping the first admin.
  has_users=$("$STILL_PREFIX/bin/still" eval \
    'IO.puts("STILL_HAS_USERS=#{Still.Accounts.has_users?()}")' 2>&1 \
    | grep '^STILL_HAS_USERS=' | tail -n1 | cut -d= -f2)

  # Skip only on an explicit "true"; anything else (a real "false", or a
  # missing sentinel from a hiccuped eval) errs toward creating an admin
  # rather than leaving a fresh install with none.
  if [ "$has_users" = "true" ]; then
    say "Admin user(s) already exist — skipping bootstrap"
  elif can_prompt || { [ -n "${STILL_ADMIN_EMAIL:-}" ] && [ -n "${STILL_ADMIN_PASSWORD:-}" ]; }; then
    say "Bootstrapping first admin user"
    "$STILL_PREFIX/bin/bootstrap"
  else
    # Piped, non-interactive install (curl | sudo sh in CI) with no admin
    # credentials: don't run the interactive prompt — it would read EOF and
    # abort the whole install under `set -e`. Point the operator at the other
    # first-admin paths instead.
    say "No terminal for the first-admin prompt — create the admin from the dashboard's setup page, or re-run with STILL_ADMIN_EMAIL and STILL_ADMIN_PASSWORD set."
  fi
fi


# -----------------------------------------------------------------------------
# Persist installed version
# -----------------------------------------------------------------------------
#
# Source of truth for upgrade detection on the next install.sh run. Written
# only after everything above succeeded so a mid-install failure leaves the
# previous tag (or no file at all) in place and re-running retries.

printf '%s\n' "$resolved_target_version" > "$STILL_ETC/installed-version"
chmod 0644 "$STILL_ETC/installed-version"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

if [ "${STILL_UPGRADE:-}" = "1" ]; then
  _banner="Still has been upgraded and restarted."
else
  _banner="Still is installed and running."
fi

cat <<EOF

$_banner

  Mode:        $STILL_MODE
  Binary:      $STILL_PREFIX/bin/still
  Config:      $env_file
  State:       $STILL_VAR
  Server ID:   $server_id

Next steps:

  # Check service status
  sudo systemctl status still

  # Tail logs
  sudo journalctl -u still -f

  # Stop / start / restart
  sudo systemctl {stop,start,restart} still

Full documentation: https://deploystill.com/docs
EOF

if [ "$STILL_MODE" = "controller" ] && [ "${STILL_UPGRADE:-}" != "1" ]; then
  _cookie=$(grep '^RELEASE_COOKIE=' "$env_local" | cut -d= -f2-)

  cat <<EOF

To add an agent to this controller:

  1. Register it on the controller and grab the returned id:

       curl -X POST https://<this-controller>/api/servers \\
         -H 'Authorization: Bearer <api-key>' \\
         -H 'Content-Type: application/json' \\
         -d '{"name":"<name>","host":"<agent-host>","roles":["application"]}'

  2. On the agent host, run the installer with that id and the cookie:

       RELEASE_COOKIE=$_cookie \\
       STILL_MODE=agent \\
       STILL_CONTROLLER_NODE=still@$STILL_NODE_HOST \\
       STILL_SERVER_ID=<id-from-step-1> \\
       sudo -E sh install.sh

     (Or run it interactively and paste each value when prompted.)

The RELEASE_COOKIE above is this controller's distribution secret — keep it private.
Lost it later? sudo grep RELEASE_COOKIE $env_local
EOF
fi
