# Claude Code remote-control agent for a Docker host.
#
# Design notes:
# - The Claude CLI is installed at FIRST BOOT into /root/.local, which compose
#   mounts as a named path under ./data/local. That makes `claude update` (and
#   the CLI's own background auto-updater) persist across container recreation.
# - A seed install is baked under /opt/claude-seed as an offline fallback only;
#   it is NOT the primary install (a volume shadows /root/.local at runtime).
# - Runs as root by design: it drives the host Docker daemon via the mounted
#   socket and works in /docker (root-owned on the host).
FROM ubuntu:24.04

ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      dnsutils \
      git \
      iproute2 \
      iputils-ping \
      jq \
      less \
      nano \
      netcat-openbsd \
      openssh-client \
      procps \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      rsync \
      tree \
      util-linux \
      zsh \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/root
# /root/.local/bin is the persisted (volume-backed) install; the seed path is a
# fallback for first boot without network.
ENV PATH="/root/.local/bin:/opt/claude-seed/.local/bin:${PATH}"

RUN mkdir -p /root/.ssh \
    && ssh-keyscan -t ed25519,rsa github.com >> /root/.ssh/known_hosts 2>/dev/null \
    && chmod 700 /root/.ssh \
    && chmod 644 /root/.ssh/known_hosts

# /docker holds many independent git repos (one per container stack), all
# root-owned host bind mounts — trust them globally.
# Do NOT pre-seed ~/.claude.json: a fabricated file without an oauthAccount
# breaks Remote Control org detection (see entrypoint.sh).
RUN mkdir -p /root/.claude /docker \
    && git config --system --add safe.directory '*'

# Offline-fallback seed install of the Claude CLI (primary install happens at
# first boot into the persisted /root/.local volume).
RUN mkdir -p /opt/claude-seed \
    && HOME=/opt/claude-seed bash -c 'curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"' \
    && /opt/claude-seed/.local/bin/claude --version

COPY entrypoint.sh healthcheck.sh /usr/local/bin/
COPY claude-login.sh /usr/local/bin/claude-login
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
      /usr/local/bin/claude-login

WORKDIR /docker

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
