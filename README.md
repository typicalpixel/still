# Still

An open-source, API-first deployment platform for bare metal Linux servers. Rolling deploys, health checks, automatic rollbacks — no containers, no Kubernetes, no vendor lock-in.

**Status: pre-alpha.** Under active development. Not recommended for production yet.

## How it works

One Elixir binary, one systemd unit, one config file. The mode is an env var:

- **Standalone** — single server runs everything. Home servers, VPS, small teams.
- **Controller** — multi-server fleet. Owns the database, exposes the API, orchestrates deploys.
- **Agent** — multi-server fleet. Runs application workloads. Talks to the controller over Erlang distribution.

Still manages Caddy (reverse proxy) and systemd (process supervision) for you. It does not run containers.

## Install

Linux only. Tested on Ubuntu 22.04 and 24.04.

```sh
curl -fsSL https://deploystill.com/install.sh | sudo sh
```

Pre-alpha: the URL above is not live yet. Run the installer directly from a checkout:

```sh
git clone https://github.com/typicalpixel/still.git
cd still
sudo sh scripts/install.sh
```

The installer asks a handful of questions. Each honors its `STILL_*` env var
if pre-set, so the same script runs unattended for CI / Ansible / Terraform.

- **Mode** (`STILL_MODE`) — `standalone` (controller + agent on one box; the
  default, and the right choice for a single server), `controller`, or
  `agent`.
- **Controller node address** (`STILL_CONTROLLER_NODE`, agents only) — where
  this agent reaches the controller over Erlang distribution, e.g.
  `still@10.0.0.1`.
- **Domain** (`STILL_CONTROLLER_DOMAIN`, controller / standalone) — the
  public hostname you reach Still on, e.g. `still.example.com`. It serves the
  LiveView dashboard at `/` and the JSON API under `/api` — same origin. Point
  its DNS at this server. Leave blank for a private install reached by raw IP:
  Caddy then host-scopes the dashboard to this machine's detected address, and
  any other `Host` gets a small "Still" page. Behind an edge that forwards a
  public hostname (Cloudflare, a cloud LB), set this to that hostname.
- **TLS** (`STILL_CONTROLLER_TLS`, controller / standalone) — does this server
  terminate HTTPS? `auto`: yes, Caddy listens on :80/:443 and provisions a
  Let's Encrypt cert (needs the domain's DNS pointed here and those ports
  reachable). `off`: no, an edge in front terminates TLS (Cloudflare, a load
  balancer) or it's a private install.
- **Node host** (`STILL_NODE_HOST`, all modes) — the address other Still
  nodes use to reach this machine over the internal control plane (controller
  ↔ agents: Erlang distribution + artifact pulls). This is *not* how users or
  your API reach you. On a standalone server nothing connects to it, so the
  detected default is fine; it only matters once you add remote agents, where
  it must be an address those agents can route to (a private/VPC IP, not
  necessarily public).
Then it writes a systemd unit, runs migrations, reconciles Caddy's base config, and — on fresh controller/standalone installs — prompts for a first admin user.

Host prerequisites:

- `caddy` on `$PATH` — `sudo apt install caddy`
- `systemctl`, `curl`, `tar` — present by default on systemd Linux

Every prompt honors its env var if pre-set, so the same script works non-interactively for Ansible / Terraform / CI. See `scripts/install.sh` for the full list of `STILL_*` vars.

## Dashboard

The dashboard is built into the Phoenix app with LiveView. Open
`http://<controller-domain>/` after install. The dashboard and API share one
origin (auth cookies/session). Caddy host-scopes the controller route to your
domain, so the dashboard at `/` and the API under `/api` never collide with
the per-app domains Still proxies — and a request on any other host gets a
small "Still" page instead of the dashboard.

## Create the first admin

A fresh controller/standalone install has no users. On an **interactive** install the script runs `bin/bootstrap`, which prompts for an admin email and password — so you finish ready to sign in. A piped or non-interactive install (`curl | sh`, Ansible) can't answer that prompt, so create the admin yourself with one of:

- **CLI** — `sudo /opt/still/bin/bootstrap` prompts for email + password, creates the admin, and prints an admin API key (shown once) to script against the API right away.
- **Dashboard** — open `http://<controller-domain>/`; a fresh instance routes you to a setup page, and filling it in signs you straight in.
- **API** — `POST /api/bootstrap`:

```sh
curl -sS -X POST $STILL_URL/api/bootstrap \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","name":"Admin","password":"..."}'
```

Returns `{"data": {"token": "...", "user": {...}}}` — a session token, so there's no separate login step. Bootstrap deliberately doesn't hand out an API key; mint one explicitly with that token (see [API keys](#api-keys)) when you need CI/CLI access. The endpoint is one-shot — it returns 409 once any user exists.

## Signing in

Once an admin exists, use the dashboard's login page, or hit the API directly:

```sh
curl -sS -X POST $STILL_URL/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"..."}'
```

Returns `{"data": {"token": "...", "user": {...}}}`. Pass the token as `Authorization: Bearer <token>` on subsequent requests.

Login is rate-limited per client IP (default 10/minute). Over the budget it returns `429` with a `Retry-After` header instead of locking the account, so a brute-force can't lock a legitimate user out.

## API keys

Session tokens are for the dashboard. For scripted and CI use, create an API key:

```sh
curl -sS -X POST $STILL_URL/api/api_keys \
  -H "Authorization: Bearer $SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"deploy-bot","permissions":["deploy","read"]}'
```

The raw key (prefixed `still_...`) is returned **once**. Save it — it's never shown again. Use it the same way as a session token.

Permissions, least to most privileged: `read`, `rollback`, `deploy`, `admin`.

## Your first deploy

### 1. Register an agent server

Skip on standalone — the installer auto-registers the local host.

```sh
curl -sS -X POST $STILL_URL/api/servers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"app-1","host":"10.0.0.10","roles":["application"]}'
```

### 2. Create an application

```sh
curl -sS -X POST $STILL_URL/api/applications \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hello",
    "type": "static_site",
    "domain": "hello.example.com",
    "min_healthy": 1,
    "artifact_source": {"type": "unauthenticated_url"}
  }'
```

Application types:

- `static_site` — serves files from a tarball via Caddy. No `exec_command`, no `health_check`. SPA fallback to `/index.html` is automatic.
- `elixir_release` — `mix release`-built tarball. Requires `exec_command` and a `health_check`.
- `process` — generic long-running binary. Requires `exec_command` and a `health_check`.

Caddy routes by `Host`, so each app needs its own `domain`. The one hostname
you can't use is the controller's own (`STILL_CONTROLLER_DOMAIN`): Still owns
that entire host for the dashboard and API, so an app claiming it would sit
behind those routes and never receive traffic — Still rejects it at create
time. The match is the exact hostname, case-insensitive; subdomains
(`app.still.example.com`) are fine. With no controller domain configured
(private/IP install) nothing is reserved.

#### Exec command, start/stop hooks

`elixir_release` and `process` apps run as a templated systemd unit, one
instance per blue/green slot. Releases unpack under
`/var/lib/still/applications/<app>/`, and the active slot is reached through a
`current_blue` / `current_green` symlink that Still flips on each deploy. The
unit's `WorkingDirectory` is the active slot, and `PORT` is injected per slot
(blue and green get different ports).

`exec_command` is how the service starts, resolved against the active slot.
Three shapes:

- **Relative (default — use this)** — `bin/hello start`. Still expands it to the
  active slot's absolute path for you. Pair it with the app's `env_vars` (stored
  by Still and exposed to the process) and you never touch a path.
- **Absolute** — write the full path yourself using systemd's `%i` slot
  placeholder: `/var/lib/still/applications/hello/current_%i/bin/hello start`.
  systemd substitutes `%i` with `blue`/`green` at launch. Equivalent to the
  relative form; reach for it only when you want to control the whole line.
- **Prefix runner** — wrap the start command in a launcher that fetches secrets
  from a secret manager and execs your binary, so secrets are pulled at launch
  (and rotate centrally) instead of being stored by Still. Because the line
  starts with `/`, Still passes it through verbatim — include the slot path
  yourself:

  ```
  /usr/bin/doppler run -- /var/lib/still/applications/hello/current_%i/bin/hello start
  ```

  [Doppler](https://www.doppler.com) is shown, but any `run -- <cmd>`-style
  launcher works identically — e.g. [Infisical](https://infisical.com)
  (`infisical run --`), HashiCorp Vault via
  [envconsul](https://github.com/hashicorp/envconsul),
  [chamber](https://github.com/segmentio/chamber) (`chamber exec --`), or
  [sops](https://github.com/getsops/sops) (`sops exec-env`). One caveat: don't
  let the secret manager define `PORT` — it would override Still's per-slot port
  and break the blue/green health check.

Two optional commands round out the unit, both resolved the same way (relative →
slot path, absolute → verbatim):

- `exec_start_pre` — runs before `exec_command` on every start (systemd
  `ExecStartPre`). Typically migrations, e.g. `bin/hello eval Hello.Release.migrate`.
- `exec_stop` — graceful shutdown command (systemd `ExecStop`), e.g. `bin/hello stop`.

#### Distributed Erlang releases

Each slot's unit gets these variables from Still, alongside your app's own
`env_vars`:

| Variable | Value |
| --- | --- |
| `PORT` | the slot's port (blue and green differ) |
| `STILL_APPLICATION` | the application name |
| `STILL_TARGET_SLOT` | `blue` or `green` — which slot this instance is |
| `STILL_NODE_HOST` | host the node advertises on |
| `STILL_RELEASE_VERSION` | the version being deployed |

If your release starts distributed Erlang — the `mix release` default, and what
lets `bin/app eval`/`rpc` run migrations — **both slots run briefly at once
during a flip**, so they must use different node names. Two BEAMs claiming the
same name on one host crash-loop the second:

```
Protocol 'inet_tcp': the name app@host seems to be in use by another Erlang node
```

Still gives you the slot but doesn't name your node for you. Fold the slot into
`RELEASE_NODE` in your release's `rel/env.sh.eex`:

```sh
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=${STILL_APPLICATION}-${STILL_TARGET_SLOT}@${STILL_NODE_HOST}
```

That yields `app-blue@…` and `app-green@…` — distinct, so both coexist during
the overlap.

### 3. Assign servers

```sh
curl -sS -X POST $STILL_URL/api/applications/hello/servers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"server_id":"<server-uuid>"}'
```

### 4. Deploy

```sh
curl -sS -X POST $STILL_URL/api/applications/hello/deployments \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"version":"0.1.0","artifact_url":"https://example.com/hello-0.1.0.tar.gz"}'
```

The response contains the deployment ID. Track progress in the dashboard, via
`GET /api/deployments/:id`, or with the unified activity feed at
`GET /api/events`.

## Rollback

Revert an application to its previous successful version:

```sh
curl -sS -X POST $STILL_URL/api/applications/hello/rollback \
  -H "Authorization: Bearer $TOKEN"
```

This runs a full rolling deploy using the prior deployment's artifact. It's strictly one step back — to go further, deploy an older version as a new deployment.

## Maintenance mode

Park an application behind a maintenance page without tearing down its deploy. Caddy serves a `503` on the app's domain instead of proxying to it — deploys still work while it's parked, and `503` tells clients and crawlers the outage is temporary. Toggle it from the application's dashboard page, or via the API:

```sh
# Enter maintenance (message optional)
curl -sS -X PATCH $STILL_URL/api/applications/hello \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"maintenance": true, "maintenance_message": "Back at 17:00 UTC"}'

# Exit maintenance
curl -sS -X PATCH $STILL_URL/api/applications/hello \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"maintenance": false}'
```

The change takes effect immediately — the route is reconciled on the controller and on each hosting agent.

## Upgrade

Upgrades are idempotent — re-run the same one-liner:

```sh
curl -fsSL https://deploystill.com/install.sh | sudo sh
```

The installer detects an existing install (via `/etc/still/installed-version` or the on-disk release), prompts to confirm the version jump, then backs up the SQLite database, extracts the new release, runs migrations, and restarts the service. Server identity, `SECRET_KEY_BASE`, `RELEASE_COOKIE`, and per-app state are preserved. If the installed version already matches the target, it exits without touching anything.

Non-interactive (CI, Ansible): `STILL_ASSUME_YES=1` skips the confirmation prompt. `STILL_FORCE_REINSTALL=1` re-runs even when the versions match. `STILL_UPGRADE=1` forces upgrade mode for repair scenarios where the on-disk signals are missing.

Fleet upgrade order: controller first (brief ~5s restart during which running apps keep serving but no new deploys can start), then each agent.

## Ports and network layout

Controller / standalone:

| Port | Service | Env var | Exposure |
|------|---------|---------|----------|
| 4000 | Phoenix (Still's API + dashboard) | `PORT` | loopback only (Caddy proxies to it) |
| 2019 | Caddy admin API | — | loopback only |
| 9090 | Caddy (artifact server) | `STILL_INTERNAL_PORT` | reachable from agents — same network as Erlang distribution |
| 80 / 443 | Caddy | — | public, only when `STILL_CONTROLLER_TLS=auto` |
| 8080 | Caddy (HTTP) | `STILL_CADDY_HTTP_PORT` | default when `STILL_CONTROLLER_TLS=off` — put it behind Cloudflare, a cloud LB, or a Tailscale hostname |

Controller and agents talk over Erlang distribution, which is symmetric — once a node opens a connection, traffic flows both ways over the dist socket. Each side needs the other reachable on EPMD (4369) and on the kernel-assigned distribution port. On Tailscale or a private network this is transparent; on public networks, firewall both sides to only accept distribution from known fleet IPs. Agents also need outbound HTTP to the controller's port 9090 to fetch artifacts. The controller reaches each agent's Caddy on `STILL_INGRESS_EDGE_PORT` (default 8080; it must match the agents' `STILL_CADDY_HTTP_PORT`).

## Operations

```sh
# Service
sudo systemctl {status,restart,stop,start} still

# Logs
sudo journalctl -u still -f

# Config
/etc/still/still.env             # rewritten on every install (derived values)
/etc/still/still.env.local       # your secrets and overrides (preserved across upgrades)
/etc/still/server.id             # host UUID (preserved across upgrades)
/etc/still/installed-version     # currently installed tag (read by install.sh on re-run)

# State
/var/lib/still/still.db             # SQLite database (controller / standalone)
/var/lib/still/applications/        # deployed app artifacts (agent / standalone)
```

### Inspecting Caddy

To see the live Caddy config a node is actually running — useful when traffic isn't routing the way you expect — admins can read it straight from the API:

```sh
curl -sS $STILL_URL/api/caddy -H "Authorization: Bearer $TOKEN"                       # the controller's own Caddy
curl -sS $STILL_URL/api/servers/<server-id>/caddy -H "Authorization: Bearer $TOKEN"   # a connected agent's Caddy
```

Or open the **Caddy** page in the dashboard (admins only) and pick a node from the dropdown.

### Surviving restarts

Still drives Caddy through its admin API, and Caddy autosaves every change. The
installer points `caddy.service` at `caddy run --resume`, so a reboot, a Caddy
upgrade, or a crash brings Caddy back on the **last config Still pushed** — your
deployed apps keep serving even while Still itself is stopped, restarting, or
being upgraded. Still re-syncs Caddy from its database whenever it comes back
up. If you manage Caddy yourself (`STILL_SKIP_CADDY_SETUP=1`), run it with
`--resume` to get the same guarantee.

## API reference

OpenAPI 3.0 spec: live at `GET /api/openapi`. The spec is generated
from `operation/3` annotations on each controller — to add a new
endpoint, declare the operation alongside the action and it shows up
automatically.

The dashboard receives live updates over LiveView. The public API for v0.1.0
is HTTP JSON only; API clients should poll `GET /api/events`,
`GET /api/deployments/:id`, or the status endpoints as needed.

---

## Local development

To work on the dashboard without a real agent or a `mix release`, seed a faked standalone install — an admin login, a server, sample apps with deploy history, all announced as connected. From an `iex -S mix phx.server` session:

```elixir
Still.Dev.Standalone.seed()        # admin + server + sample apps, connected
Still.Dev.Standalone.disconnect()  # take the host offline (realtime views update)
Still.Dev.Standalone.reconnect()   # bring it back online
Still.Dev.Standalone.reset()       # remove the seeded apps, server, and dev admin
```

`seed/0` is idempotent — re-running it leaves existing rows alone — and prints the dev admin's email and password to sign in with. `reset/0` is the inverse, returning the instance to fresh. These helpers are dev-only and not wired into the running app.

## Running the tests

### Unit tests

```sh
mix test
```

Runs the default suite. Integration tests are excluded by default.

### Integration tests

Integration tests exercise the real deployment path end-to-end: they spawn a dedicated Caddy instance on free ports, download prebuilt fixture artifacts from [typicalpixel/static_site](https://github.com/typicalpixel/static_site) and [typicalpixel/elixir_release](https://github.com/typicalpixel/elixir_release), shell out to `curl` / `tar` / `systemctl`, and assert real HTTP responses flip between versions.

Two categories, both excluded by default.

#### `:integration` — no root required

Covers the `static_site` deploy path (download, unpack, symlink, Caddy flip) and controller ↔ agent communication over Erlang distribution. Safe to run on any Linux machine with the prerequisites.

```sh
mix test --include integration
```

**Host prerequisites:**

- `caddy` on `$PATH` — `sudo apt install caddy`. The test harness spawns its own Caddy on random ports, so any globally-installed Caddy service should be disabled: `sudo systemctl disable --now caddy`.
- `tar`, `systemctl` — default on every systemd Linux.
- Network access to `github.com` on first run (fixture tarballs are cached under `test/support/fixtures/cache/` after).

#### `:integration_root` — requires root

Covers `elixir_release` and `process` deploy paths, which write systemd units to `/etc/systemd/system/`, run `systemctl daemon-reload`, and start/stop real processes under systemd.

```sh
sudo -E mix test --only integration_root
```

If you use `mise` or `asdf` to manage Elixir, `sudo` will reset `PATH` to its `secure_path`. Workaround:

```sh
sudo -E env "PATH=$PATH" mix test --only integration_root
```

**Do not run this on your primary dev machine unless you trust the test artifacts.** Prefer a dedicated VM — the test creates real systemd units under `/etc/systemd/system/` and real application directories under `/var/lib/still/applications/`.

If you run `:integration_root` tests without being root, the affected modules skip with a clear reason — they do not fail. Same if a host executable is missing for any category.

### CI

Both `:integration` and `:integration_root` run on standard GitHub-hosted Ubuntu runners. The root suite uses passwordless `sudo` available on those runners. Runners are ephemeral, so the systemd units and `/var/lib/still/applications/` entries written during the test are destroyed with the VM.

## Caddy

Still leans hard on [Caddy](https://caddyserver.com/) for ingress and TLS, and we love it. We're not affiliated with, endorsed by, or sponsored by the Caddy project or [ZeroSSL](https://zerossl.com/) — we're just fans driving its admin API. Caddy is its own project under its own license; go give it a star.

## License

MIT © 2026 [Thomas Athanas](https://github.com/typicalpixel)
