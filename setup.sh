#!/bin/bash
set -e

cd "$(dirname "$0")"

# The image tag every service is pinned to. All four images (console,
# relay, nginx, agent) are built,
# tested and released as a SET -- there is no protocol version
# negotiation between console, relay and agent, so a mismatched set
# fails as a connection problem with nothing pointing at versions as
# the cause. Change this in one place, or not at all.
SPARTA_VERSION_DEFAULT="REPLACE_ME"

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

echo "✓ Docker detected: $(docker --version)"
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

    if grep -q '^SPARTA_VERSION=' .env; then
        CURRENT_VERSION=$(grep '^SPARTA_VERSION=' .env | head -n1 | cut -d= -f2-)
        if [ "$CURRENT_VERSION" = "$SPARTA_VERSION_DEFAULT" ]; then
            echo "✓ Version already ${SPARTA_VERSION_DEFAULT} — no change needed"
        else
            sed -i "s|^SPARTA_VERSION=.*|SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}|" .env
            if grep -q "^SPARTA_VERSION=${SPARTA_VERSION_DEFAULT}$" .env; then
                echo "✓ Version updated: ${CURRENT_VERSION} → ${SPARTA_VERSION_DEFAULT}"
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
        else
            echo "ERROR: could not add SPARTA_VERSION to .env."
            exit 1
        fi
    fi
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

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║  Sparta Console is ready!                          ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "  Open your browser and complete the setup wizard:"
echo ""
echo "  → https://${SERVER_IP}:8443"
echo ""
echo "  That is this server's own network address. If you are"
echo "  reaching it from another machine, substitute whatever"
echo "  address you use for this host."
echo ""
echo "  Then start the relay — it is NOT started by this"
echo "  script, and nothing starts it for you:"
echo ""
echo "      docker compose --profile relay up -d relay"
echo ""
echo "  The --profile flag is required. Without it the relay"
echo "  is silently skipped and no agent can connect."
echo ""
echo "  Your browser will warn about the certificate: nginx"
echo "  serves a temporary self-signed one until the wizard"
echo "  installs the real one. Safe to proceed."
echo ""

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
echo "     Then move that copy OFF this server. It is mode 600"
echo "     because it holds secrets — keep your copy at least"
echo "     as protected."
echo ""
echo "  NOTE: Restrict port 8443 to your own IP in your"
echo "  firewall or security group. This is the admin console"
echo "  — never open it to 0.0.0.0/0."
echo ""
