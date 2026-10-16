# Sparta — Self-Hosted Secure Database Tunnel

Sparta lets an application reach a database that lives somewhere it
cannot normally get to — behind a firewall, on a private network, in
another cloud — without opening that database to the internet and
without a VPN.

This package installs the **relay side**: the console you administer it
from, the relay itself, and the TLS front end. Agents are installed
separately, on the networks where your databases and applications live —
see *Agents* below.

---

## What is in this package

| File | Purpose |
|---|---|
| `setup.sh` | Installer. Generates secrets, pulls images, starts the console. |
| `docker-compose.yml` | Service definitions. Images pinned via `SPARTA_VERSION`. |
| `README.md` | This file. |

Nothing else is needed. There is no source tree to build.

---

## Requirements

- A Linux host with **Docker** and the **Docker Compose v2 plugin**
  - `apt install docker.io` does **not** include Compose v2. On
    Ubuntu/Debian you also need `apt install docker-compose-v2`.
- **openssl** (present on most server distributions)
- Registry credentials. The images are private, so pulling them needs a
  read-only credential. If you do not have one, email hello@sparta.systems
  and ask for access.
- A **licence**. Sparta runs only with one: without it no tunnel is
  served and none can be created. Registering brings a 30-day trial
  licence with the registry credential — a file ending in `.sparlic`.
- Inbound network access to the host on ports **443** and **8443**
  (see *Firewall* below)

The installer checks Docker, Compose v2 and openssl, and stops with a
clear message if any is missing. It cannot check your credentials or
your firewall.

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
> for evaluation, not recommended for production. An install that
> starts in IP mode can move to domain mode later, under
> **Settings → Deployment mode**, without reinstalling.

### Then activate your licence

Sign in, open **Settings**, and in the licence card choose **Activate
License Key**. Choose your `.sparlic` file and click **Activate
License**.

Until a licence is active, a notice above every page says so, and
nothing can be created. Once it is active, the same place shows the
licence's last day whenever there is something to act on. A trial covers
one tunnel for 30 days. A paid licence runs to the end of its paid
period and then for a 14-day grace period. When a licence ends without a
new one activated, **every tunnel stops** — nothing is deleted, and
everything comes back when a valid licence is activated, with no Apply
Config and nothing to do on any agent's host. The console manual
(**Documentation → Licensing**) has the details.

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

### Optional: set a support address

The console shows a contact address to the people who use it. It ships
empty, and shows nothing at all until you set one. To set it, add this
to `.env` in your install directory:

    SPARTA_SUPPORT_EMAIL=support@yourcompany.example

Then restart the console:

    docker compose up -d console

Changing it later needs only that edit and a restart, never a
reinstall.

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

## Agents

Agents are **not** part of this package, and do not run here. They run
on the networks where your databases and applications live — that is
the point of the product.

Every tunnel has a **Data Agent**, and a tunnel in Bridged mode also has
an **App Agent**. They are not interchangeable:

| Agent | Runs where | Inbound firewall |
|---|---|---|
| **Data Agent** | A machine that can reach your database | **None.** It only connects out. |
| **App Agent** | A machine your application can reach | **Yes** — the local port you choose. |

The traffic path is: your application → App Agent → relay → Data Agent
→ your database. In Direct mode there is no App Agent: your application
connects to the relay's port for the data source.

An agent is one program, run as a systemd service on a Linux host. It is
installed from one file, the **agent installer**, which your console
carries and gives to an administrator; the agent inside it is the
version your console was built with.

### Agent hosts

An agent host needs:

- **x86_64**, running **systemd**, with **glibc 2.34 or newer**.
  Tested: **RHEL 9, Ubuntu 22.04 and Debian 12.** The installer checks the
  machine, glibc and systemd, and refuses — saying why — on a host that
  does not meet them.
- **`sudo`**, to install the agent as a system service.
- **Outbound** access to the relay on 443. Nothing inbound, except an App
  Agent's local port.
- These commands, from these packages. Most are on any server install;
  **`openssl` is missing from minimal Ubuntu and Debian images**, and the
  installer will not run without it — it is what checks the agent's
  signature, and the installer never skips that check and never installs
  a package itself.

  | Commands | RHEL 9 | Ubuntu 22.04, Debian 12 |
  |---|---|---|
  | `sh` | `bash` | `dash` |
  | `head` `tail` `od` `wc` `tr` `sha256sum` `mktemp` `install` `env` `readlink` `ln` `mv` `cat` `rm` `chmod` `rmdir` `id` `uname` `sleep` `cut` | `coreutils` (or `coreutils-single`) | `coreutils` |
  | `getconf` `getent` | `glibc-common` | `libc-bin` |
  | `groupadd` `useradd` (and `userdel` `groupdel` for `--purge`) | `shadow-utils` | `passwd` |
  | `flock` | `util-linux-core` | `util-linux` |
  | `sed` `tar` `gzip` `openssl` | the same names | the same names |
  | `systemctl` `journalctl` | `systemd` | `systemd` |
  | `sudo` | `sudo` | `sudo` |

  On an SELinux host the installer also uses `restorecon` and
  `selinuxenabled` (`policycoreutils`, `libselinux-utils`) when they are
  present, to give its files their default labels.

> **Ubuntu 25.10 and later are not yet tested.** From 25.10 Ubuntu
> replaces the core commands above and `sudo` with Rust rewrites
> (`coreutils-from-uutils`, `sudo-rs`). The installer has been proven on
> the commands RHEL 9, Ubuntu 22.04 and Debian 12 ship.

### Installing an agent

The steps, with the exact command for that agent, are on the tunnel in
the console: open its **Details**, then the **Data Agent** or **App
Agent** panel, and follow **Installing the agent**. In outline:

1. Download the agent installer (`sparta-agent-install.sh`) from the
   panel. Only an administrator can download the installer or a config:
   a config holds the agent's secret.
2. Download that agent's config from the same panel — `agent_config.yaml`
   for a Data Agent, `agent_config_listen.yaml` for an App Agent.
3. Copy both files to the agent's host, into one directory.
4. Run the one command the panel shows. It checks the host and the
   config before changing anything, installs the agent, puts the config
   where only the agent's own service account can read it, and starts
   the agent as a service that also starts at boot.
5. Check that it is running, with the status command the panel shows.

**Use the command the panel gives you** rather than writing your own.
Each agent's service is named after its tunnel and role
(`sparta-agent@<name>`), and the console works that name out. One host
can run the agents of several tunnels, each under its own name; the same
installer file installs any agent of your console.

The installer leaves a control command on the host,
**`/usr/local/sbin/sparta-agent`**, which takes the same options without
needing the installer file again. Always give it with its full path:
`sudo` on the RHEL family does not search `/usr/local/sbin`.

### Checking the installer before you run it

The installer verifies its own signature before it installs anything,
with the host's `openssl`, and has no option to skip that. If your
security team wants to check it by hand first, the file's own header —
plain text, readable with `head -n 60 sparta-agent-install.sh` — gives
the commands: how to cut out the script, the signature and the agent,
check the signature with `openssl`, and print the signing key's
fingerprint. Compare that fingerprint with the one published at
`https://<download-url>/codesign-fingerprint.txt`.

### What an agent can do on its host

- It runs as one system user, `sparta-agent`, shared by every agent on
  the host — so one agent's config is readable by another agent on the
  same host. Each config sits in `/etc/sparta/<name>.yaml`, mode 600.
- It is contained by systemd's sandbox: `NoNewPrivileges`,
  `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`,
  `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`,
  `ProtectControlGroups`, an empty capability set, network families
  limited to IPv4, IPv6 and Unix sockets, `@system-service` system calls
  only, and nothing executable outside its own directory and the
  system's library directories.
- Under SELinux it runs **unconfined** (`unconfined_service_t`); the
  systemd sandbox is what contains it.
- The installer makes no network call and installs no package. It
  creates the `sparta-agent` user and group, installs and enables the
  agent's systemd unit, and otherwise touches only its own files.
- An agent reports its version to the relay, and the console shows it on
  the tunnel list. That version is the agent's own word, for
  information; nothing is allowed or refused on it.

### The App Agent's local port

The App Agent listens on a port you choose in its panel *before*
downloading its config: from 1024 to 65535, free on its host. The config
holds the port.

It listens on **every network interface** of its host, so any machine
that can reach the host on that port can use the tunnel. Point your
application at that host and port, and open the port in the host's
firewall to your application and to nothing wider.

### Changing an agent's config

An agent reads its config when it starts, and nothing sends it a new
one. Whenever something the config holds changes in the console — the
agent's secret, the relay's address, its proxy or CA, the tunnel's data
sources, an App Agent's port — the agent goes on using what it has until
you give it the new file.

The steps are in the agent's panel, under **Updating a running agent**:
download the config again, copy it to the host, and run the replace
command shown. **Replacing a config restarts the agent**, which
interrupts the connections going through it. The new config is checked
first, and if the agent does not start on it, the previous one is put
back.

A **Data Agent** has a second way, for a change to its data sources
only: put the file in place and reload, as the panel shows. That
interrupts nothing. A reload applies data source changes and nothing
else; if anything else in the file changed, it refuses, says so, and
applies nothing.

### Seeing what your agents are doing

```bash
sudo /usr/local/sbin/sparta-agent --list
```

lists the agents on the host and what each is doing. For one agent, use
the status and log commands its panel shows:
`systemctl status sparta-agent@<name>` gives one status line — the
relay's state and the last reload's outcome — and
`sudo journalctl -u sparta-agent@<name>` gives its log. Reading the log
needs root, or membership of a group that may read the journal (on
RHEL 9: `adm`, `systemd-journal` or `wheel`).

### Taking an agent out

```bash
sudo /usr/local/sbin/sparta-agent --uninstall --name <name>
```

stops the agent and keeps it from starting at boot. **Its config is
kept** — and that config holds the tunnel's secret; add `--purge` to
remove it as well. When the last config on a host is purged, the agent
leaves the host entirely: every version, the systemd unit, the control
command and the `sparta-agent` user. The journal stays. The `<name>` is
the one `--list` shows. If the agent's config is gone for good, revoke
or rotate its credential in the console.

---

## Back up your `.env`

**Do this now, not later.**

`.env` in your install directory holds `DB_ENCRYPTION_KEY`. That key is
the only thing that can decrypt the credentials Sparta issued to your
agents. Keep a copy somewhere other than this server.

If you lose it, your tunnels and data sources survive, but every agent
identity becomes unreadable, and every agent will need a newly issued
credential and config. **If that happens, write to hello@sparta.systems
before changing anything.**

Your actual data lives in Docker volumes and would survive deleting the
install directory. `.env` would not — leaving you with data that
nothing can read. Back up both:

```bash
# the key
cp /opt/sparta/.env ~/sparta-env-backup      # then move it OFF this server

# the database
docker volume ls | grep sparta               # confirm the volume names
```

`setup.sh` creates `.env` as `600`. The console then regroups it to `660`
so its unprivileged process can write the wizard's output; you keep
ownership. Keep your own backup copy at `600`.

---

## Replacing the server certificate

Sparta presents a TLS certificate to browsers and to agents, and every
certificate expires — lifetimes vary by issuer, commonly from a few
months to a year. Nothing renews it for you.

**The ordinary way to replace it is in the console**, under
**Settings → TLS Certificate**. That panel shows the certificate nginx
is configured to serve and its expiry, warns inside 30 days, validates
the new pair before writing anything, and reloads nginx for you. Use it
if you can reach it. In IP address mode there is no certificate of your
own to replace: a certificate of your own comes with a change to domain
mode, under **Settings → Deployment mode**.

This section is for when you cannot — an expired certificate makes
browsers warn before they let you through, and some refuse outright.
The procedure below needs shell access to the machine running Sparta.

### First, find the paths your install actually uses

The certificate paths are written into the nginx config when Sparta is
installed, and they differ between installs — a self-signed install
points somewhere else entirely. **Read your own config rather than
assuming**, or you will replace a file nginx is not reading and nothing
will change:

```bash
docker exec sparta-nginx sh -c \
  "grep -h 'ssl_certificate' /etc/sparta/nginx/*.conf | sort -u"
```

A typical install prints:

```
ssl_certificate     /etc/sparta/certs/cert.pem;
ssl_certificate_key /etc/sparta/certs/key.pem;
```

Those are paths **inside the container**. The directory is a Docker
volume, and this is where it lives on the host:

```bash
docker volume inspect sparta_sparta_certs --format '{{.Mountpoint}}'
```

If your `ssl_certificate` line names a different directory, find its
volume with `docker volume ls | grep sparta` and inspect that one
instead.

### Replace the two files

Copy your new certificate and key over the existing files, keeping the
same names:

```bash
CERTS=$(docker volume inspect sparta_sparta_certs --format '{{.Mountpoint}}')

sudo cp fullchain.pem "$CERTS/cert.pem"
sudo cp privkey.pem   "$CERTS/key.pem"
sudo chown 999:999    "$CERTS/cert.pem" "$CERTS/key.pem"
sudo chmod 644        "$CERTS/cert.pem"
sudo chmod 600        "$CERTS/key.pem"
```

**Use the full chain, not the server certificate alone.** Agents verify
the whole chain, and a leaf-only file is the most common replacement
that looks correct and still fails at connection time.

The ownership matters: nginx reads these as uid 999, and a file it
cannot read fails the same way a missing one does.

### What happens next

Nothing to restart. nginx watches these files and picks up the change on
its own, normally within about ten seconds:

- it hashes both files every 5 seconds
- it acts only when the hash is **stable across two polls**, so it never
  reloads between your two `cp` commands
- it then runs `nginx -t`, which reads and validates the certificate
  pair, not just the config syntax
- only if that passes does it run `nginx -s reload`

**If the pair is bad, nothing happens to your running server.** The
`nginx -t` fails, the reload is skipped, the previous certificate keeps
being served, and the watcher retries on the next change. A mismatched
key or a truncated file cannot take the listener down.

Confirm it took:

```bash
docker logs sparta-nginx --tail 20 | grep -i certificate
```

`Certificate changed - reloading nginx...` means it reloaded. Then check
what is actually being served:

```bash
echo | openssl s_client -connect localhost:443 -servername YOUR_DOMAIN 2>/dev/null \
  | openssl x509 -noout -subject -issuer -enddate
```

### Connected agents are not interrupted

`nginx -s reload` starts new workers and lets existing connections
drain, so agents hold their WebSocket through it. No reconnection is
needed and no tunnel drops. This is a reload, not a restart —
`docker restart sparta-nginx` **would** drop the agent connections, and
is not needed here.

---

## Upgrading

Upgrading Sparta is two separate jobs: **the server** (console, nginx,
relay) and **each agent host**. They are upgraded differently, and the
agents are the part most easily missed.

### The server

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
directory for the new version:** a fresh directory has no `.env`, so the
installer would generate a *new* encryption key and every existing agent
identity would become unreadable.

Release archives never contain `.env`, so extraction cannot overwrite
yours.

`setup.sh` updates the version in `.env` for you and leaves every other
value untouched. It does not restart the relay, which is why the last
command is separate — `setup.sh` will remind you.

**Check the extraction actually happened.** `tar` reports success even
when it writes nothing — for example if the install directory is not
writable by your user. The old `setup.sh` then runs and prints a
benign-looking "version already X" message, and you are still on the old
release with no error anywhere.

```bash
grep SPARTA_VERSION_DEFAULT /opt/sparta/setup.sh
```

That must show the version you just downloaded. If it shows the old one,
the extraction did nothing — check the directory's ownership and
re-extract with `sudo` if needed.

**Your database is migrated automatically.** If a release changes the
schema, the console takes a backup first and applies the change at
startup, reporting both in `docker logs sparta-console` including the
backup's path. If a release changes nothing, you will see a single
`Database schema up to date` line and no backup is taken — that is
normal, not a failed upgrade. Should a migration ever fail, the console
**refuses to start** rather than run against a half-changed database,
and names the backup it took.

### Each agent host

Upgrading the server does not upgrade any agent. After the server, on
each agent host, run the installer **downloaded from the upgraded
console** (any agent's panel offers it) with `--upgrade`:

```bash
sudo sh sparta-agent-install.sh --upgrade
```

One run upgrades every agent on that host. Agents that were running are
restarted on the new version; an agent that was stopped is left
stopped. If an agent does not come back, the host is put back on the
version it was running. The tunnel list in the console shows the version
each agent reports.

The control command left on the host carries no agent, so an upgrade
always needs the downloaded installer. An older installer than the one
installed is refused unless you add `--allow-downgrade`.

### Upgrading from 0.1.9

0.1.10 changes two things that an install of 0.1.9 or earlier meets once:

- **A licence is required.** An install with no licence stops every
  tunnel when the upgraded console starts. Have your licence file ready
  and activate it straight after the upgrade (*Then activate your
  licence*, above); the tunnels come back as soon as it is active, with
  no Apply Config and nothing to do on any agent's host.
- **Agents are no longer containers.** Replace each agent's container
  with an agent installed from the console:
  1. Check the agent's host against *Agent hosts*, above. A host that
     does not meet them needs replacing with one that does.
  2. From the tunnel's panel in the upgraded console, download the
     installer and that agent's config. An App Agent needs its local port
     entered first (1024–65535).
  3. On the host, stop and remove the agent's container
     (`docker rm -f <container>`).
  4. Install the agent with the command the panel shows.

  Replace every agent when you upgrade the server; do not leave
  container agents running against an upgraded server.

### Rolling back

**The server.** Set `SPARTA_VERSION` in `.env` back to the previous
version, then bring the stack up directly:

```bash
cd /opt/sparta
docker compose --profile relay up -d
```

**Do not re-run `./setup.sh` to roll back.** Extraction already replaced
it with the *new* release's copy, and it rewrites `SPARTA_VERSION` in
`.env` to its own version unconditionally. It reports this as
`✓ Version updated: <old> → <new>` — a success message in the opposite
direction to the one you asked for, leaving you on the release you were
trying to leave.

Alternatively, re-extract the previous release's tarball over
`/opt/sparta` and run *its* `setup.sh`. That makes the old version the
installer's own default, so reconciliation carries `.env` down for you.

**An agent host.** One earlier version is kept on each host:

```bash
sudo /usr/local/sbin/sparta-agent --rollback
```

puts every agent on the host back on the version the last `--upgrade`
replaced, restarting those that are running. A second `--rollback` goes
forward again.

---

## Troubleshooting

**First: what is the relay actually serving?**

Most confusing symptoms come down to a gap between what the console
shows and what the relay has loaded. The console holds the tunnels you
created; the relay serves only what is in its own config file. Those can
differ — when a licence does not cover a tunnel, after a tunnel is
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

**Nothing can be created, or every tunnel has stopped.**
Read the notice above every page in the console: it says whether no
licence is active or which licence ended, and when. Activate a valid
licence under **Settings**; tunnels come back without Apply Config. An
agent that was turned away while the tunnels were stopped retries every
few minutes, so allow that long — or restart it on its host to force the
attempt.

**A tunnel is shown as suspended, or its agent is rejected with
`Unknown tunnel_id`.**
More tunnels are configured than the licence covers. The oldest keep
working up to the licence's number; the rest are suspended — not
deleted — and come back, oldest first, when a licence covering them is
activated or another tunnel is deleted. The agent's message is
misleading in this one case: from the relay's side the tunnel is simply
not there.

**Agents will not connect.**
Check that a licence is active, that port 443 is reachable from the
agent's network, and that the relay is actually running
(`docker compose ps` — remember the `--profile relay` flag). Then read
the agent's own log on its host (`sudo journalctl -u
sparta-agent@<name>`).

**An agent still will not connect after I corrected its credential.**
The relay reports a rejected credential as a permanent failure, and the
agent then retries only every **5 minutes** — so a correct fix can look
like no fix at all for that long. Its log reads `Auth failed. This looks
permanent, not a network issue … Retrying in 300s`. Run
`sudo systemctl restart sparta-agent@<name>` on its host to force the
attempt immediately.

**An agent keeps restarting, or will not start.**
systemd restarts a failed agent every five seconds for as long as it is
enabled. `systemctl status sparta-agent@<name>` shows its state, and the
reason is in its log, not on the terminal: `sudo journalctl -u
sparta-agent@<name>`. To stop the retries, take it out with
`--uninstall` (*Taking an agent out*, above).

**`systemctl reload` failed.**
The terminal shows only `Job for … failed` and a pointer to
`systemctl status` and `journalctl`; the reason is in the agent's log.
Most often the new file changed something other than data sources,
which a reload refuses: use the replace command in the agent's panel
instead.

**A data source address change had no effect.**
The agent is still using its old config. Give it the new one, as
*Changing an agent's config* describes. To confirm, compare the address
in the relay config (the command at the top of this section) with the
address the agent's log says it is dialling.

**An agent's log says `[Errno 16] Device or resource busy` when it
connects.**
The host resolves names through a lookup module that the agent's
sandbox cannot load — one outside `/usr/lib64` or
`/usr/lib/x86_64-linux-gnu`, typically from a third-party directory or
identity product. Give the agent a relay address it can resolve without
that module, such as one in `/etc/hosts` or ordinary DNS.

**An agent's log is gone after a reboot.**
On RHEL 9 the journal is kept in memory only, by default. To keep it
across reboots, create its directory and restart the journal service:
`sudo mkdir -p /var/log/journal && sudo systemctl restart
systemd-journald`.

**After stopping an agent, `systemctl status` still says "connected".**
systemd keeps the last status line an agent wrote. The unit's own state,
on the line above it, is what to read.

**Every tunnel reads "relay offline" but the relay looks healthy.**
The services find each other by container name. Do not change
`container_name` in `docker-compose.yml`.

**Image pull fails.**
Confirm `docker login` succeeded with the credentials from your
registration email, and that `SPARTA_VERSION` in `.env` names a real
release.

**What to send when you contact support.**

Sparta is self-hosted, so we cannot look at your install. A first
message containing these things usually replaces a day of
back-and-forth:

1. the redacted relay config, from the command at the top of this
   section
2. `curl -sk https://localhost:8443/api/meta`, run on the Sparta host
3. `docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'`, run
   on the Sparta host
4. on the agent's host: `sudo /usr/local/sbin/sparta-agent --list`, and
   `sudo journalctl -u sparta-agent@<name> -n 200`

**Never send `.env`, an unredacted `relay_config.yaml`, or any agent
config** (`agent_config.yaml`, `agent_config_listen.yaml`, or a file
under `/etc/sparta` on an agent host). Each carries live secrets.

---

## Uninstalling

```bash
cd /opt/sparta
docker compose --profile relay down          # stops everything
docker compose --profile relay down -v       # ALSO DELETES ALL DATA
```

`-v` removes the volumes holding your database, certificates and
configuration. There is no undo. Agents are taken out on their own
hosts — see *Taking an agent out*, above.
