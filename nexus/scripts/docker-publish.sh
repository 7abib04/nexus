#!/usr/bin/env bash
# Builds, tags, and pushes every buy-01 service image to the Nexus
# docker-hosted repository, then confirms `docker pull` works from Nexus.
#
# Usage (from the repo root):
#   ./nexus/scripts/docker-publish.sh [version]
#
# Env vars:
#   NEXUS_DOCKER_REGISTRY   default: localhost:8086 (docker-hosted, see
#                           nexus/docker-compose.yml)
#   NEXUS_DEPLOY_USER       default: jenkins-deployer (see nexus/provision.sh)
#   NEXUS_DEPLOY_PASSWORD   default: changeit-jenkins-deployer
#
# `localhost:8086` qualifies for Docker's automatic loopback "insecure
# registry" exemption, so no daemon.json changes are needed for local pushes.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${1:-$(date +%Y%m%d%H%M%S)-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}"
REGISTRY="${NEXUS_DOCKER_REGISTRY:-localhost:8086}"
NEXUS_DEPLOY_USER="${NEXUS_DEPLOY_USER:-jenkins-deployer}"
NEXUS_DEPLOY_PASSWORD="${NEXUS_DEPLOY_PASSWORD:-changeit-jenkins-deployer}"

SERVICES="discovery-service gateway-service user-service product-service media-service order-service"

log() { echo "[docker-publish] $*"; }

log "logging in to $REGISTRY as $NEXUS_DEPLOY_USER"
echo "$NEXUS_DEPLOY_PASSWORD" | docker login "$REGISTRY" -u "$NEXUS_DEPLOY_USER" --password-stdin

for svc in $SERVICES; do
    image="$REGISTRY/buy01/$svc"
    log "building $svc -> $image:$VERSION"
    docker build \
        -f "$REPO_ROOT/backend/Dockerfile" \
        --build-arg "SERVICE_MODULE=$svc" \
        -t "$image:$VERSION" \
        -t "$image:latest" \
        "$REPO_ROOT/backend"

    log "pushing $image:$VERSION and :latest"
    docker push "$image:$VERSION"
    docker push "$image:latest"
done

log "building frontend -> $REGISTRY/buy01/frontend:$VERSION"
docker build \
    -f "$REPO_ROOT/frontend/Dockerfile" \
    -t "$REGISTRY/buy01/frontend:$VERSION" \
    -t "$REGISTRY/buy01/frontend:latest" \
    "$REPO_ROOT/frontend"
docker push "$REGISTRY/buy01/frontend:$VERSION"
docker push "$REGISTRY/buy01/frontend:latest"

log "verifying retrieval: pulling $REGISTRY/buy01/gateway-service:$VERSION back down"
docker rmi "$REGISTRY/buy01/gateway-service:$VERSION" >/dev/null 2>&1 || true
docker pull "$REGISTRY/buy01/gateway-service:$VERSION"

log "done. Published version: $VERSION"
