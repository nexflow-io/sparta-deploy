# Sparta — Self-Hosted Secure Database Tunnel

Sparta lets an application reach a database that lives somewhere it
cannot normally get to — behind a firewall, on a private network, in
another cloud — without opening that database to the internet and
without a VPN.

This package installs the **relay side**: the console you administer it
from, the relay itself, and the TLS front end. Agents are deployed
separately, on the networks where your databases and applications live.

---

## What is in this package

| File | Purpose |
|---|---|
| `setup.sh` | Installer. Generates secrets, pulls images, starts the console. |
| `docker-compose.yml` | Service definitions. Pinned to one release version. |
| `README.md` | This file. |

Nothing else is needed. There is no source tree to build.

---

## Requirements

- A Linux host with **Docker** and the **Docker Compose v2 plugin**
  - `apt install docker.io` does **not** include Compose v2. On
    Ubuntu/Debian you also need `apt install docker-compose-v2`.
- **openssl** (present on most server distributions)
- Registry credentials — emailed to you when you registered
- Inbound network access to the host on ports **443** and **8443**
  (see *Firewall* below)

The installer checks all three prerequisites and stops with a clear
message if any is missing.

---

## Install

Choose a permanent location. **This directory is your install root, not
a temporary download** — see *Back up your .env* below.

```bash
curl -fsSLO https://<download-url>/sparta-<version>.tar.gz
sudo mkdir -p /opt/sparta
sudo tar xzf sparta-<version>.tar.gz -C /opt/sparta
sudo chown -R "$(id -un):$(id -gn)" /opt/sparta
cd /opt/sparta

docker login          # use the credentials from your registration email

./setup.sh
```

`setup.sh` will:

1. Check Docker, Compose v2 and openssl
2. Generate this install's encryption keys into `.env`
3. Pull the Sparta images
4. Start the console and wait until it is genuinely healthy

It prints the console URL when it finishes.

### Then complete the setup wizard

Open the URL it printed — `https://<your-server>:8443`.

Your browser will warn about the certificate. That is expected: the TLS
front end serves a temporary self-signed certificate until the wizard
installs the real one. Accept it and continue.

The wizard asks for your deployment mode (domain name or IP address),
your TLS certificate, the port range for tunnels, and an admin
username and password.

> **Domain mode is strongly preferred.** With a real certificate,
> agents verify the relay's TLS identity. In IP mode a self-signed
> certificate is generated for you and agents cannot verify it — usable
> for evaluation, not recommended for production.

### Then start the relay

The relay is **not** started by `setup.sh`, and nothing starts it for
you:

```bash
docker compose --profile relay up -d relay
```

The `--profile relay` flag is required. Without it the relay is
silently skipped and no agent can connect.

This is deliberate. The relay publishes the tunnel port range you chose
in the wizard, and a published port range cannot be changed on a
running container. Starting it before the wizard would publish the
wrong range.

---

## Firewall

| Port | Open to | Why |
|---|---|---|
| **443** | The addresses your agents connect out from. `0.0.0.0/0` only if those addresses are unknown or change. | The one path agents use to reach the relay. |
| **8443** | **Your admin IP only — never `0.0.0.0/0`.** | The admin console. |
| Your tunnel range | Whatever connects to your databases through Sparta. | Chosen in the wizard; defaults to 15000–15200. |

Agents dial *out* to the relay, so 443 only needs to accept connections
from the networks your agents run on. Many sites egress through a small,
fixed set of addresses — if yours does, scope the rule to them. Open it
to the world only when you cannot enumerate them.

**Port 443 serves exactly one path.** The relay's WebSocket endpoint,
and nothing else. Requests to any other path are refused, and the admin
console is **not** reachable on 443 — it exists only on 8443, as a
separate listener. Every agent connection is authenticated before it is
accepted.

Port **80 is not published.** There is no HTTP-to-HTTPS redirect;
`http://your-server` will simply refuse the connection. Use `https://`.

If you would rather not expose 8443 at all, reach the console over an
SSH tunnel instead:

```bash
ssh -L 8443:localhost:8443 user@your-server -N
```

then browse to `https://localhost:8443`.

---

## Deploying agents

Agents are **not** part of this package, and do not run here. They run
on the networks where your databases and applications live — that is
the point of the product.

Every tunnel has **two** agents, and they are not interchangeable:

| Agent | Runs where | Inbound firewall |
|---|---|---|
| **Data Agent** | A machine that can reach your database | **None.** It only connects out. |
| **App Agent** | A machine your application can reach | **Yes** — the local port you choose. |

The traffic path is: your application → App Agent → relay → Data Agent
→ your database.

### Getting each agent's config

Create a tunnel in the console, open that tunnel's **Details** panel on
the Tunnels page, and download a config for **each** role. The two files
are different and are not interchangeable:

| Role | Downloaded file |
|---|---|
| Data Agent | `agent_config.yaml` |
| App Agent | `agent_config_listen.yaml` |

Each holds the relay URL, the tunnel identifier and that agent's own
credential.

Next to each download button the console shows the exact `docker run`
command for that role. **Use the command the console gives you** rather
than writing your own — the App Agent's includes port flags that depend
on the local port you chose, and both include two flags that must stay
together.

### `chmod 600` and `--user` go together

The config file holds a live tunnel secret, so the console's commands
set it to mode 600 and run the container as your own uid and gid:

```bash
--user $(id -u):$(id -g)
```

**Both are required together.** With a 600 file and no `--user`, the
agent cannot read its own config and will not start.

### The App Agent's local port

The App Agent listens on a port you choose in the console *before*
downloading its config. Point your application at the App Agent host on
that port — the port is reachable by any machine on your network that
can reach that host, not just the host itself.

Set the port in the console and the value is baked into the downloaded
file. Leave it blank and the file uses a `${LISTEN_PORT}` placeholder
instead, so the same file can be deployed on several machines with each
one choosing its port at run time.

This port must be open on that machine's firewall.

### Version matching

Agents must run the **same release version** as this install. There is
no version negotiation between components, so a mismatched set fails as
a connection problem with nothing pointing at versions as the cause.

---

## Changing a data source address

A running Data Agent picks up a new data source address **without being
redeployed** — the relay session survives and live streams are not
dropped.

But the agent reads its data sources from the config file it has
mounted, and nothing pushes a new file to it. The new address has to
reach that file first:

1. Click **Apply Config** on the Tunnels page
2. Re-download that tunnel's **Data Agent** config
3. Overwrite the file the container already mounts — **in place**
4. Reload the agent:

```bash
docker kill -s HUP sparta-data-agent
```

**Do not skip steps 2 and 3.** A reload re-reads the *same* file. If the
file has not changed, the agent reports a successful reload with no
changes and carries on using the old address — and nothing, anywhere,
reports an error.

**Overwrite in place — do not replace the file.** The container mounts
that single file by inode. `mv` swaps in a different file and the agent
keeps reading the old one; `sed -i` and most editors do the same, since
they write a temporary file and rename it. Use `cp`, `cat >`, or `scp`
straight over the existing path. If the file has already been replaced,
no reload can pick it up — but you do not have to recreate the
container: `docker restart <container>` re-resolves the mount, and the
agent reads the new file.

After you click Apply Config the console names the tunnels that need
this.

### What a reload does not cover

Reload applies to data source addresses **only**. The following are read
when the agent establishes its connection to the relay, so changing any
of them needs a freshly downloaded config and a `docker restart` — but
not a redeployed container:

- the tunnel identifier
- a rotated tunnel secret
- the relay URL

**One change, and only one, needs the container recreated:** the App
Agent's local port. A published port cannot be changed on a running
container.

Sending `SIGHUP` to an App Agent is harmless: it logs that it is
declining the reload and keeps running.

---

## Back up your `.env`

**Do this now, not later.**

`.env` in your install directory holds `DB_ENCRYPTION_KEY`. That key is
the only thing that can decrypt the credentials Sparta issued to your
agents. Keep a copy somewhere other than this server.

If you lose it:

- your tunnels and data sources survive
- but every agent identity becomes unreadable, and **every agent must
  be redeployed** with a freshly downloaded config

Your actual data lives in Docker volumes and would survive deleting the
install directory. `.env` would not — leaving you with data that
nothing can read. Back up both:

```bash
# the key
cp /opt/sparta/.env ~/sparta-env-backup      # then move it OFF this server

# the database
docker volume ls | grep sparta               # confirm the volume names
```

`.env` is `chmod 600` because it holds secrets. Keep your copy at least
as protected.

---

## Upgrading

Extract the new release **over** your existing install directory, then
re-run the installer:

```bash
cd /opt/sparta
curl -fsSLO https://<download-url>/sparta-<new-version>.tar.gz
tar xzf sparta-<new-version>.tar.gz
./setup.sh
docker compose --profile relay up -d relay
```

Extracting over the top is intentional. It keeps `.env` — and therefore
your encryption key — exactly where it is. **Do not create a new
directory for the new version:** a fresh directory has no `.env`, so
the installer would generate a *new* encryption key and every existing
agent identity would become unreadable.

Release archives never contain `.env`, so extraction cannot overwrite
yours.

`setup.sh` updates the version in `.env` for you and leaves every other
value untouched. Remember to upgrade your agents to the same version.

To roll back, set `SPARTA_VERSION` in `.env` back to the previous
version and re-run `./setup.sh`.

---

## Troubleshooting

**First: what is the relay actually serving?**

Most confusing symptoms come down to a gap between what the console
shows and what the relay has loaded. The console holds the tunnels you
created; the relay serves only what is in its own config file. Those can
differ — after a licence limit is exceeded, after a tunnel is
deactivated, or when a change was never applied.

```bash
docker exec sparta-relay sh -c \
  "sed -n '/^tunnels:/,/^relay:/p' /etc/sparta/relay_config.yaml \
   | sed 's/secret: .*/secret: <redacted>/'"
```

That prints every tunnel the relay is serving and the data source
address it holds for each. **A tunnel missing from that output is not
being served, whatever the console shows.**

> Run it exactly as written. The file holds live tunnel secrets in plain
> text, and the command redacts them *inside* the container so they
> never reach your shell history. Do not `cat` the file, and never send
> its raw contents to anyone.

**The console will not start.**
```bash
docker compose logs console
```
Do **not** delete `.env` — it holds this install's encryption key.

**The installer says `.env` is incomplete.**
A previous run was interrupted. If this install has never worked,
`rm .env && ./setup.sh`. If it *has* worked before, do not delete it —
restore `.env` from your backup instead.

**Agents will not connect.**
Check that port 443 is reachable from the agent's network, that the
relay is actually running (`docker compose ps` — remember the
`--profile relay` flag), and that the agent is on the same release
version as this install.

**An agent still will not connect after I corrected its credential.**
The relay reports a rejected credential as a permanent failure, and the
agent then retries only every **5 minutes** — so a correct fix can look
like no fix at all for that long. Its log reads `Auth failed. This looks
permanent, not a network issue … Retrying in 300s`. Run
`docker restart <container>` to force the attempt immediately rather
than waiting it out.

**A tunnel looks normal in the console, but its agent is rejected with
`Unknown tunnel_id`.**

The tunnel exceeded your licence limit and was removed from the relay's
config. The tunnel still exists and its secret is still valid — the
agent's message is misleading in this one case, because from the relay's
side the tunnel is simply not there. Look for an amber *Tunnel
deactivated* line in the console's activity log.

To restore it: upload a valid licence key, then **click Apply Config**.
Nothing restores a tunnel on its own — enforcement only ever removes.
The agent reconnects within five minutes, or immediately if you run
`docker restart <container>`.

**An agent starts and immediately exits.**
Check its logs for a permissions error reading the config. A mode 600
config needs `--user $(id -u):$(id -g)` on the `docker run` command.

**A data source address change had no effect.**
The agent was reloaded without a fresh config file. Follow all four
steps in *Changing a data source address* above — a reload alone
re-reads the file the agent already has.

To confirm that is what happened, compare the address in the relay
config (the command at the top of this section) against the address your
agent's logs say it is dialling. If they differ, the agent is holding a
stale file.

**Every tunnel reads "relay offline" but the relay looks healthy.**
The services find each other by container name. Do not change
`container_name` in `docker-compose.yml`.

**Image pull fails.**
Confirm `docker login` succeeded with the credentials from your
registration email, and that `SPARTA_VERSION` in `.env` names a real
release.

**What to send when you contact support.**

Sparta is self-hosted, so we cannot look at your install. A first
message containing these four things usually replaces a day of
back-and-forth:

1. the redacted relay config, from the command at the top of this
   section
2. `docker logs --tail 200 <your agent container>`
3. `curl -sk https://localhost:8443/api/meta`, run on the Sparta host
4. `docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'`

**Never send `.env`, an unredacted `relay_config.yaml`, or any
`agent_config.yaml`.** Each carries live secrets.

---

## Uninstalling

```bash
cd /opt/sparta
docker compose --profile relay down          # stops everything
docker compose --profile relay down -v       # ALSO DELETES ALL DATA
```

`-v` removes the volumes holding your database, certificates and
configuration. There is no undo.
