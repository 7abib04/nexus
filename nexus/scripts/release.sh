#!/usr/bin/env bash
# Bumps the backend reactor version, builds, and deploys every module's
# JAR to the matching Nexus repository (maven-releases for a plain version,
# maven-snapshots for a `-SNAPSHOT` version) - demonstrates artifact
# versioning end to end for nexus/README.md.
#
# Usage (from the repo root):
#   NEXUS_DEPLOY_USER=jenkins-deployer NEXUS_DEPLOY_PASSWORD=... \
#     ./nexus/scripts/release.sh 1.0.0
#
# Then retrieve that exact version back out of Nexus with:
#   mvn dependency:get -s nexus/settings.xml.template \
#     -Dartifact=com.buy01:product-service:1.0.0 -Dtransitive=false

set -euo pipefail

NEW_VERSION="${1:?usage: release.sh <new-version> (e.g. 1.0.0 or 1.1.0-SNAPSHOT)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export NEXUS_URL="${NEXUS_URL:-http://localhost:8085}"
export NEXUS_DEPLOY_USER="${NEXUS_DEPLOY_USER:-jenkins-deployer}"
export NEXUS_DEPLOY_PASSWORD="${NEXUS_DEPLOY_PASSWORD:-changeit-jenkins-deployer}"

log() { echo "[release] $*"; }

cd "$REPO_ROOT/backend"

log "setting reactor version to $NEW_VERSION"
mvn -q -B -ntp versions:set -DnewVersion="$NEW_VERSION" -DgenerateBackupPoms=false

log "building and deploying every module's artifact to Nexus"
mvn -B -ntp -s "$REPO_ROOT/nexus/settings.xml.template" clean deploy -DskipTests

target_repo="maven-releases"
case "$NEW_VERSION" in
    *-SNAPSHOT) target_repo="maven-snapshots" ;;
esac

log "done. Version $NEW_VERSION is now retrievable from $NEXUS_URL/repository/$target_repo/"
log "browse: $NEXUS_URL/#browse/browse:$target_repo"
log "retrieve a specific artifact any time with, e.g.:"
log "  mvn dependency:get -s $REPO_ROOT/nexus/settings.xml.template -Dartifact=com.buy01:product-service:$NEW_VERSION -Dtransitive=false"
