#!/bin/bash
set -e

cd "$(dirname "$0")"

# The image tag every service is pinned to. The three images (console,
# relay, nginx) are built, tested and released as a SET -- there is no
# protocol version negotiation between them, so a mismatched set fails
# as a connection problem with nothing pointing at versions as the
# cause. Change this in one place, or not at all. Agents are not images:
# each agent host is upgraded with the installer the console carries.
SPARTA_VERSION_DEFAULT="REPLACE_ME"

# What this run found and did, for the closing banner (B6, 0.1.14). The
# banner used to branch on "an .env exists" alone and then announced an
# upgrade, a changed version line and a relay on the old version -- none
# of it checked. A rerun with nothing changed, a rerun before the wizard
# ("There is NO wizard to complete"), and a rollback (README: run the
# older release's setup.sh) all got that text. It now says only what is
# set here and measured after the console is healthy (SETUP_STATE,
# RELAY_STATE below).
HAD_ENV=0
VERSION_STATE=fresh     # fresh | unchanged | changed | added
VERSION_FROM=""

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║           Sparta — Self-Hosted Relay               ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""

# ── Check prerequisites ──────────────────────────────────
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed."
    echo "Install Docker: https://docs.docker.com/engine/install/"
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "ERROR: Docker Compose v2 is not installed."
    echo ""
    echo "Docker itself is present, but the Compose v2 plugin is separate."
    echo "On Ubuntu/Debian, 'apt install docker.io' installs Docker without it:"
    echo ""
    echo "    sudo apt install docker-compose-v2"
    echo ""
    echo "Other platforms: https://docs.docker.com/compose/install/"
    exit 1
fi

# openssl generates both startup secrets below. It is checked here
# because the failure is otherwise SILENT and PERMANENT: the key
# generation is a pipeline, so a missing openssl leaves the variable
# empty while the pipeline still exits 0 and `set -e` does not fire.
# The console then fails closed on an empty DB_ENCRYPTION_KEY, and
# .env has already been written -- so re-running this script skips
# generation entirely and the broken state survives.
if ! command -v openssl &> /dev/null; then
    echo "ERROR: openssl is not installed."
    echo ""
    echo "It is needed to generate this install's encryption keys."
    echo "On Ubuntu/Debian:  sudo apt install openssl"
    echo "On RHEL/Rocky:     sudo dnf install openssl"
    exit 1
fi

# Each check above says when it passed, not only the first (R6). --short
# is in every Compose v2 this script has met; the full line is the
# fallback.
echo "✓ Docker detected: $(docker --version)"
echo "✓ Docker Compose detected: $(docker compose version --short 2>/dev/null || docker compose version)"
echo "✓ openssl detected: $(openssl version)"
echo ""

# ── Refuse to continue on a half-written .env ────────────
# Presence is not completeness. Any interruption during generation --
# Ctrl-C, a full disk, a failed sed -- leaves a .env that an
# existence-only check would happily skip, starting a console that
# cannot boot. Validate the contents instead.
if [ -f .env ]; then
    if grep -qE '^(DB_ENCRYPTION_KEY|CONSOLE_SECRET_KEY)=(__[A-Z]+__)?$' .env; then
        echo "ERROR: .env exists but is incomplete."
        echo ""
        echo "One of the generated secrets is empty or unsubstituted,"
        echo "which means a previous run of this script did not finish."
        echo ""
        echo "If this install has never worked, delete .env and re-run:"
        echo ""
        echo "    rm .env && ./setup.sh"
        echo ""
        echo "If it HAS worked before, do NOT delete .env -- the"
        echo "encryption key in it is the only thing that can read your"
        echo "existing database. Restore it from your backup instead."
        exit 1
    fi
    # ── Version reconciliation ────────────────────────────
    # An upgrade extracts the new release OVER this directory and
    # deliberately does NOT touch .env -- that is what preserves
    # DB_ENCRYPTION_KEY. But SPARTA_VERSION lives in .env too, and
    # compose reads every image tag from it. Leaving .env entirely
    # alone therefore means compose pulls the OLD images while every
    # message in this script reports success.
    #
    # Rewrite that ONE line and nothing else. The pattern is
    # ^-anchored: an unanchored match would also hit a secret whose
    # value happens to contain the string SPARTA_VERSION=, silently
    # corrupting the encryption key.
    #
    # sed exits 0 whether or not it matched, so verify afterwards
    # rather than trusting the exit status.
    echo "✓ Existing .env found — preserving your secrets"
    HAD_ENV=1

    if grep -q '^SPARTA_VERSION=' .env; then
        CURRENT_VERSION=$(grep '^SPARTA_VERSION=' .env | head -n1 | cut -d= -f2-)
        if [ "$CURRENT_VERSION" = "$SPARTA_VERSION_DEFAULT" ]; then
            echo "✓ Version already ${SPARTA_VERSION_DEFAULT} — no change needed"
            VERSION_STATE=unchanged
        else
            sed -i "s|^SPARTA_VERSION=.*|SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}|" .env
            if grep -q "^SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}$" .env; then
                echo "✓ Version updated: ${CURRENT_VERSION} → ${SPARTA_VERSION_DEFAULT}"
                VERSION_STATE=changed
                VERSION_FROM=$CURRENT_VERSION
            else
                echo "ERROR: failed to update SPARTA_VERSION in .env."
                echo ""
                echo "Set it by hand and re-run this script:"
                echo ""
                echo "    SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}"
                echo ""
                echo "Do NOT delete .env -- it holds this install's"
                echo "encryption key."
                exit 1
            fi
        fi
    else
        # .env predates version pinning, or the line was removed.
        echo "SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}" >> .env
        if grep -q "^SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}$" .env; then
            echo "✓ Version line added: ${SPARTA_VERSION_DEFAULT}"
            VERSION_STATE=added
        else
            echo "ERROR: could not add SPARTA_VERSION to .env."
            exit 1
        fi
    fi

    # .env's mode is NOT set here (B6 (b), 0.1.14). Until the wizard has
    # run, the console's entrypoint gives .env to its group with mode 660
    # so the wizard can write the port range -- but only when the console
    # STARTS. A rerun at the same version restarts nothing, so a chmod 600
    # here took the wizard's write away, and the wizard swallowed the
    # error: the relay then published the default ports, not the ones
    # chosen. The mode is set after the health check below, and only once
    # the console says setup is complete.
else
    echo "Creating default .env..."
    cat > .env << EOF
# Sparta host environment
# Generated by setup.sh
# DO NOT EDIT manually unless you know what you are doing
SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}
PORT_RANGE_START=15000
PORT_RANGE_END=15200
DB_ENCRYPTION_KEY=__DBKEY__
CONSOLE_SECRET_KEY=__SECRETKEY__
EOF
    chmod 600 .env

    # Fernet key format: 32 url-safe base64 bytes. The console fails
    # closed at startup without this (crypto.py), so it must exist
    # before the first `docker compose up`, not be generated later by
    # the wizard -- the wizard is served by the console that cannot
    # boot without it.
    DBKEY=$(openssl rand -base64 32 | tr '+/' '-_')

    # CONSOLE_SECRET_KEY is validated at startup (auth/service.py) and
    # rejects empty or short values, and docker-compose passes an unset
    # host variable through as an empty string rather than an absent
    # one -- so without this the console cannot boot and the wizard
    # that would generate it is unreachable.
    SECRETKEY=$(openssl rand -hex 32)

    # Assert BEFORE writing. Both of the above are pipelines or command
    # substitutions whose failure modes are quiet; an empty value here
    # produces a console that crash-loops behind a banner saying it is
    # ready.
    if [ -z "$DBKEY" ] || [ ${#DBKEY} -lt 40 ]; then
        echo "ERROR: failed to generate DB_ENCRYPTION_KEY (got ${#DBKEY} chars)."
        rm -f .env
        exit 1
    fi
    if [ -z "$SECRETKEY" ] || [ ${#SECRETKEY} -lt 40 ]; then
        echo "ERROR: failed to generate CONSOLE_SECRET_KEY (got ${#SECRETKEY} chars)."
        rm -f .env
        exit 1
    fi

    sed -i "s|__DBKEY__|${DBKEY}|" .env
    sed -i "s|__SECRETKEY__|${SECRETKEY}|" .env

    # Confirm the substitutions actually landed. sed reports success
    # whether or not it matched anything.
    if grep -q '__DBKEY__\|__SECRETKEY__' .env; then
        echo "ERROR: .env placeholders were not substituted."
        rm -f .env
        exit 1
    fi

    echo "✓ Default .env created"
fi

# INTERNAL_TOKEN is deliberately NOT seeded. The relay reads it from
# relay_config.yaml first (event_poster.py) and only falls back to the
# environment, and the wizard writes both that config and the console
# env file. Seeding it here would leave a stale value in .env that
# matches neither end.

# ── Check the version tag is real ────────────────────────
if grep -q '^SPARTA_VERSION=REPLACE_ME$' .env; then
    echo ""
    echo "ERROR: SPARTA_VERSION is not set to a real release tag."
    echo ""
    echo "Edit .env and set SPARTA_VERSION to the version you were"
    echo "given, then re-run this script."
    exit 1
fi

# ── Pull images ───────────────────────────────────────────
# Deliberately NOT silenced. These images are the only way to run
# Sparta -- there is no source tree to build from -- so a failed pull
# is fatal, not cosmetic. It previously ran as
# `pull --quiet 2>/dev/null || true`, which hid the error, the exit
# code and the output all three.
#
# --profile relay is REQUIRED and its absence was a SECOND, separate
# hole in the same line. The relay carries profiles: ["relay"] in
# docker-compose.yml, so a bare `pull` silently skips it: this script
# validated two of the three images and printed complete success, and
# a missing relay-<version> tag surfaced later, by hand, as agents
# that could not connect. Verified 2026-08-28: with the flag, compose
# pulls 3/3.
echo "Pulling Sparta images..."
if ! docker compose --profile relay pull; then
    echo ""
    echo "ERROR: could not pull the Sparta images."
    echo ""
    echo "Common causes:"
    echo "  - no outbound network access from this host"
    echo "  - not logged in to the registry (run: docker login)"
    echo "  - SPARTA_VERSION in .env names a tag that does not exist"
    exit 1
fi
echo "✓ Images pulled"

# ── Start console + nginx ─────────────────────────────────
echo ""
echo "Starting Sparta Console..."
docker compose up -d console nginx

# ── Wait for the console to actually be healthy ──────────
# The previous version printed "Sparta Console is ready!" immediately
# after `up -d` returned, which reports that containers were CREATED,
# not that they work. That banner has printed over a crash-looping
# console behind a 502.
echo ""
echo -n "Waiting for the console to become healthy"
HEALTHY=0
for _ in $(seq 1 60); do
    STATUS=$(docker inspect --format '{{.State.Health.Status}}' sparta-console 2>/dev/null || echo "missing")
    if [ "$STATUS" = "healthy" ]; then
        HEALTHY=1
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

if [ "$HEALTHY" -ne 1 ]; then
    echo ""
    echo "ERROR: the console did not become healthy within 120s."
    echo ""
    echo "It is running but not serving. Check its logs:"
    echo ""
    echo "    docker compose logs console"
    echo ""
    echo "Do NOT delete .env -- it holds this install's encryption key."
    exit 1
fi

# ── What this run can say ─────────────────────────────────
# Asked, not assumed (B6). SETUP_STATE uses the console entrypoint's own
# test -- the one that decides .env's mode -- so the banner and the mode
# below agree with the console. Anything but those two words (the exec
# failed) is "unknown", and the banner says it could not tell.
SETUP_STATE=$(docker exec sparta-console sh -c \
    'grep -qx SETUP_COMPLETE=true /var/sparta/env/.env && echo complete || echo not-complete' \
    2>/dev/null || true)
case "$SETUP_STATE" in
    complete|not-complete) ;;
    *) SETUP_STATE=unknown ;;
esac

# The relay as Docker reports it. "current" needs BOTH its tag naming
# this release AND its image being the one that tag names now, so a tag
# pulled again since the relay started counts as not current. No image
# name is written here: the container's own tag is used.
RELAY_STATE=absent
RELAY_TAG=""
RELAY_WHY=""
if RELAY_INFO=$(docker inspect --format '{{.State.Status}} {{.Image}} {{.Config.Image}}' sparta-relay 2>/dev/null); then
    read -r RELAY_STATUS RELAY_IMAGE_ID RELAY_TAG <<< "$RELAY_INFO"
    case "$RELAY_STATUS" in
        running)
            TAG_ID=$(docker image inspect --format '{{.Id}}' "$RELAY_TAG" 2>/dev/null || true)
            if [ "${RELAY_TAG##*:}" != "relay-${SPARTA_VERSION_DEFAULT}" ]; then
                RELAY_STATE=other
                RELAY_WHY="${RELAY_TAG##*:}"
            elif [ -z "$TAG_ID" ] || [ "$TAG_ID" != "$RELAY_IMAGE_ID" ]; then
                RELAY_STATE=other
                RELAY_WHY="an earlier pull of ${RELAY_TAG##*:}"
            else
                RELAY_STATE=current
            fi
            ;;
        restarting) RELAY_STATE=restarting ;;
        *) RELAY_STATE=stopped ;;
    esac
fi

# ── .env's mode, once setup is complete ──────────────────
# The console's entrypoint makes .env 600 at every start once setup is
# complete; this covers a run that restarts nothing. Before the wizard
# (or when the console could not be asked) the mode is left as the
# console set it -- see the note in the version step above.
ENV_MODE_WAS=""
if [ "$SETUP_STATE" = complete ]; then
    MODE_BEFORE=$(stat -c '%a' .env)
    chmod 600 .env
    [ "$MODE_BEFORE" = 600 ] || ENV_MODE_WAS=$MODE_BEFORE
fi

print_wizard_steps() {
    echo "  Open your browser and complete the setup wizard:"
    echo ""
    echo "  → https://<your-server-address>:8443"
    echo ""
    echo "  Use whatever address you already reach this host on."
    echo "  The console listens on all interfaces, so any address"
    echo "  that reaches this host works."
    echo ""
    echo "  Then start the relay — it is NOT started by this"
    echo "  script, and nothing starts it for you:"
    echo ""
    echo "      docker compose --profile relay up -d relay"
    echo ""
    echo "  The --profile flag is required. Without it the relay"
    echo "  is silently skipped and no agent can connect."
    echo ""
    echo "  After the wizard, restart the console once:"
    echo ""
    echo "      docker compose restart console"
    echo ""
    echo "  That closes .env again (see below)."
    echo ""
    echo "  Your browser will warn about the certificate: nginx"
    echo "  serves a temporary self-signed one until the wizard"
    echo "  installs the real one. Safe to proceed."
    echo ""
}

print_relay_line() {
    case "$RELAY_STATE" in
        current)
            echo "  ✓ The relay is running ${SPARTA_VERSION_DEFAULT}."
            ;;
        other)
            echo "  ⚠  The relay is still running ${RELAY_WHY}."
            echo "     This script does not restart it. Bring it up on"
            echo "     ${SPARTA_VERSION_DEFAULT}:"
            echo ""
            echo "      docker compose --profile relay up -d relay"
            ;;
        restarting)
            echo "  ⚠  The relay is restarting over and over. See why:"
            echo ""
            echo "      docker compose logs relay"
            ;;
        *)
            echo "  The relay is not running. Start it:"
            echo ""
            echo "      docker compose --profile relay up -d relay"
            echo ""
            echo "  The --profile flag is required. Without it the relay"
            echo "  is silently skipped and no agent can connect."
            ;;
    esac
    echo ""
}

print_console_address() {
    echo "  → https://<your-server-address>:8443"
    echo ""
    echo "  Use whatever address you already reach this host on."
    echo "  The console listens on all interfaces, so any address"
    echo "  that reaches this host works."
    echo ""
}

# The version line, for every run that found an .env. "Running B (was
# A)", never "upgraded": README's Rolling back runs an older release's
# setup.sh, which moves the version DOWN.
print_version_line() {
    case "$VERSION_STATE" in
        changed)
            echo "  Now on ${SPARTA_VERSION_DEFAULT} (was ${VERSION_FROM}): this run changed"
            echo "  the version line in .env and nothing else in it."
            ;;
        added)
            echo "  Now on ${SPARTA_VERSION_DEFAULT}: this run added the version line"
            echo "  to .env and changed nothing else in it."
            ;;
        *)
            echo "  On ${SPARTA_VERSION_DEFAULT}. The version in .env was already"
            echo "  ${SPARTA_VERSION_DEFAULT}."
            echo ""
            echo "  If you extracted a new release before this run, this"
            echo "  is still the old setup.sh: see README.md, Upgrading,"
            echo "  \"Check the extraction actually happened\"."
            ;;
    esac
    echo ""
}

echo ""
if [ "$HAD_ENV" -eq 0 ] && [ "$SETUP_STATE" = complete ]; then
    # Q2 (ruled 2026-11-21): no .env here, but this host's console was set
    # up before -- .env deleted, or a new install directory (compose's
    # fixed project name gives every directory on the host the same
    # volumes). This run has just generated a NEW encryption key next to
    # data written with the old one. Stop before the backup advice below:
    # copying THIS .env over the customer's backup would destroy the one
    # copy of the key that reads their data.
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  STOP — this console was set up before             ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    echo "  There was no .env in $(pwd),"
    echo "  so this run made one with a NEW encryption key. But"
    echo "  this host's Sparta data was set up by an earlier"
    echo "  install, and only the earlier key can read it."
    echo ""
    echo "  (Installing into a new directory does this: the data"
    echo "  lives in Docker volumes that every Sparta directory on"
    echo "  this host shares.)"
    echo ""
    echo "  Put the earlier .env back in place of this one — from"
    echo "  your backup, or from the directory you installed in"
    echo "  before — then run ./setup.sh again."
    echo ""
    echo "  Do NOT back up this .env over your existing backup:"
    echo "  the key in it reads nothing."
    echo ""
    echo "  Until then the console cannot read the credentials"
    echo "  it issued to your agents. Its log says so:"
    echo ""
    echo "      docker compose logs console"
    echo ""
    exit 1
fi

if [ "$HAD_ENV" -eq 0 ]; then
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  Sparta Console is ready!                          ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    print_wizard_steps
elif [ "$SETUP_STATE" = complete ]; then
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  Sparta Console is running                         ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    print_version_line
    echo "  There is NO wizard to complete. This script does not"
    echo "  touch your admin account, tunnels, certificates or"
    echo "  data."
    echo ""
    if [ -n "$ENV_MODE_WAS" ]; then
        echo "  Made .env mode 600 (owner only); it was ${ENV_MODE_WAS}."
        echo ""
    fi
    print_console_address
    print_relay_line
    if [ "$VERSION_STATE" = changed ] || [ "$VERSION_STATE" = added ]; then
        echo "  Agent hosts are not changed by this script: download"
        echo "  the installer from this console (any agent's panel)"
        echo "  and run it there with --upgrade."
        echo ""
    fi
elif [ "$SETUP_STATE" = not-complete ]; then
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  Sparta Console is running — setup not done        ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    print_version_line
    print_wizard_steps
    if [ "$RELAY_STATE" != absent ] && [ "$RELAY_STATE" != stopped ]; then
        echo "  The relay is already running: it was started before"
        echo "  the wizard. The relay command above, run after the"
        echo "  wizard, recreates it with the ports you choose there."
        echo ""
    fi
else
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  Sparta Console is running                         ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""
    print_version_line
    echo "  Could not ask the console whether its setup is"
    echo "  complete (docker exec sparta-console failed)."
    echo ""
    echo "  If you have NOT completed the setup wizard yet:"
    echo ""
    print_wizard_steps
    echo "  If you HAVE completed it, there is no wizard to run."
    echo ""
    print_relay_line
fi

# ── Back up .env ─────────────────────────────────────────
# Two failure paths above tell the customer to "restore .env from your
# backup" and one tells them not to delete it -- but nothing anywhere
# ever told them to MAKE a backup. Both of those messages are read at
# a point where it is already too late to act on them.
#
# This is the only moment the precondition can still be established:
# the key exists, the install works, and nothing has gone wrong yet.
echo "  ⚠  BACK UP .env NOW — before you go further."
echo ""
echo "     It holds DB_ENCRYPTION_KEY, the only thing that can"
echo "     decrypt the credentials Sparta issues to your agents."
echo "     Your data lives in Docker volumes and would survive"
echo "     losing this directory. This key would not, leaving"
echo "     you with data nothing can read."
echo ""
echo "         cp $(pwd)/.env ~/sparta-env-backup"
echo ""
echo "     Then move that copy OFF this server. setup.sh"
echo "     makes .env mode 600. Until the setup wizard has"
echo "     run, the console regroups it to 660 so it can"
echo "     write the wizard's answers; you keep ownership."
echo "     From the console's first start after the wizard"
echo "     it is 600 again. Keep your backup copy at 600."
echo ""
echo "  NOTE: Port 8443 is the admin console — never open it"
echo "  to 0.0.0.0/0. Open it to your own IP only, or not at"
echo "  all and reach the console over an SSH tunnel (see"
echo "  README.md, Firewall)."
echo ""
