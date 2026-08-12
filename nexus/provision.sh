#!/usr/bin/env bash
# Provisions Nexus Repository Manager for buy-01: Maven (proxy/hosted/group),
# Docker (proxy/hosted/group), and RBAC (service-account users + roles
# scoped to specific repositories). Safe to re-run - every step checks
# whether the object already exists before creating it.
#
# Usage:
#   cd nexus
#   docker compose up -d
#   ./provision.sh
#
# Env vars (all optional, defaults shown):
#   NEXUS_URL              http://localhost:8085
#   NEXUS_ADMIN_PASSWORD   the password this script will set for `admin`
#                          (default: changeit-nexus-admin) - on first run the
#                          script reads the auto-generated random password out
#                          of the container and rotates it to this value.
#   NEXUS_JENKINS_PASSWORD password for the `jenkins-deployer` CI service
#                          account (default: changeit-jenkins-deployer)
#   NEXUS_READONLY_PASSWORD password for the `dev-readonly` account
#                          (default: changeit-dev-readonly)

set -euo pipefail

# No-op outside Git Bash on Windows; prevents MSYS from mangling the
# absolute /nexus-data/... container paths below into host Windows paths.
export MSYS_NO_PATHCONV=1

NEXUS_URL="${NEXUS_URL:-http://localhost:8085}"
NEXUS_ADMIN_PASSWORD="${NEXUS_ADMIN_PASSWORD:-changeit-nexus-admin}"
NEXUS_JENKINS_PASSWORD="${NEXUS_JENKINS_PASSWORD:-changeit-jenkins-deployer}"
NEXUS_READONLY_PASSWORD="${NEXUS_READONLY_PASSWORD:-changeit-dev-readonly}"
CONTAINER_NAME="${NEXUS_CONTAINER_NAME:-buy01-nexus}"

log() { echo "[provision] $*"; }

wait_for_nexus() {
    log "waiting for Nexus at $NEXUS_URL to report STARTED..."
    for _ in $(seq 1 60); do
        set +e
        state="$(curl -s -o /dev/null -w '%{http_code}' "$NEXUS_URL/service/rest/v1/status/writable")"
        set -e
        if [ "$state" = "200" ]; then
            log "Nexus is up."
            return 0
        fi
        sleep 5
    done
    echo "Nexus did not become ready in time" >&2
    exit 1
}

resolve_admin_credentials() {
    if docker exec "$CONTAINER_NAME" test -f /nexus-data/admin.password 2>/dev/null; then
        initial_password="$(docker exec "$CONTAINER_NAME" cat /nexus-data/admin.password)"
        log "first run detected (random initial admin password) - rotating it to NEXUS_ADMIN_PASSWORD"
        curl -fsS -u "admin:${initial_password}" \
            -X PUT "$NEXUS_URL/service/rest/v1/security/users/admin/change-password" \
            -H 'Content-Type: text/plain' \
            --data-raw "$NEXUS_ADMIN_PASSWORD" >/dev/null
        AUTH="admin:${NEXUS_ADMIN_PASSWORD}"
    else
        log "admin password already rotated on a previous run, using NEXUS_ADMIN_PASSWORD"
        AUTH="admin:${NEXUS_ADMIN_PASSWORD}"
    fi
}

api() {
    # api METHOD PATH [JSON_BODY]
    method="$1"; path="$2"; body="${3:-}"
    if [ -n "$body" ]; then
        curl -fsS -u "$AUTH" -X "$method" "$NEXUS_URL$path" \
            -H 'Content-Type: application/json' -d "$body"
    else
        curl -fsS -u "$AUTH" -X "$method" "$NEXUS_URL$path"
    fi
}

repo_exists() {
    # Capture into a variable before comparing rather than piping curl's
    # stdout straight into grep - the latter is flaky here (MSYS/Windows
    # pipe timing between the two forked processes under `set -o pipefail`).
    code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$NEXUS_URL/service/rest/v1/repositories/$1")"
    [ "$code" = "200" ]
}

create_repo_if_missing() {
    name="$1"; create_path="$2"; body="$3"
    if repo_exists "$name"; then
        log "repository '$name' already exists, skipping"
    else
        log "creating repository '$name'"
        api POST "$create_path" "$body" >/dev/null
    fi
}

role_exists() {
    code="$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/roles/$1")"
    [ "$code" = "200" ]
}

create_role_if_missing() {
    id="$1"; body="$2"
    if role_exists "$id"; then
        log "role '$id' already exists, skipping"
    else
        log "creating role '$id'"
        api POST "/service/rest/v1/security/roles" "$body" >/dev/null
    fi
}

user_exists() {
    # Avoids a jq dependency: the users-by-id endpoint returns a JSON array
    # containing the matching userId field when found, "[]" otherwise.
    body="$(curl -fsS -u "$AUTH" "$NEXUS_URL/service/rest/v1/security/users?userId=$1")"
    printf '%s' "$body" | grep -q "\"userId\"[[:space:]]*:[[:space:]]*\"$1\""
}

create_user_if_missing() {
    id="$1"; body="$2"
    if user_exists "$id"; then
        log "user '$id' already exists, skipping"
    else
        log "creating user '$id'"
        api POST "/service/rest/v1/security/users" "$body" >/dev/null
    fi
}

### 0. wait + admin bootstrap ################################################
wait_for_nexus
resolve_admin_credentials

### 1. Maven repositories (proxy, hosted x2, group) ###########################
create_repo_if_missing "maven-central" "/service/rest/v1/repositories/maven/proxy" '{
  "name": "maven-central",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "proxy": {"remoteUrl": "https://repo1.maven.org/maven2/", "contentMaxAge": 1440, "metadataMaxAge": 1440},
  "negativeCache": {"enabled": true, "timeToLive": 1440},
  "httpClient": {"blocked": false, "autoBlock": true},
  "maven": {"versionPolicy": "RELEASE", "layoutPolicy": "STRICT"}
}'

create_repo_if_missing "maven-releases" "/service/rest/v1/repositories/maven/hosted" '{
  "name": "maven-releases",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "ALLOW_ONCE"},
  "component": {"proprietaryComponents": true},
  "maven": {"versionPolicy": "RELEASE", "layoutPolicy": "STRICT"}
}'

create_repo_if_missing "maven-snapshots" "/service/rest/v1/repositories/maven/hosted" '{
  "name": "maven-snapshots",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "ALLOW"},
  "component": {"proprietaryComponents": true},
  "maven": {"versionPolicy": "SNAPSHOT", "layoutPolicy": "STRICT"}
}'

create_repo_if_missing "maven-public" "/service/rest/v1/repositories/maven/group" '{
  "name": "maven-public",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": false},
  "group": {"memberNames": ["maven-releases", "maven-snapshots", "maven-central"]}
}'

### 2. Docker repositories (hosted, proxy, group) ##############################
create_repo_if_missing "docker-hosted" "/service/rest/v1/repositories/docker/hosted" '{
  "name": "docker-hosted",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "ALLOW"},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8086}
}'

create_repo_if_missing "docker-proxy" "/service/rest/v1/repositories/docker/proxy" '{
  "name": "docker-proxy",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "proxy": {"remoteUrl": "https://registry-1.docker.io", "contentMaxAge": 1440, "metadataMaxAge": 1440},
  "negativeCache": {"enabled": true, "timeToLive": 1440},
  "httpClient": {"blocked": false, "autoBlock": true},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8087},
  "dockerProxy": {"indexType": "HUB", "useTrustStoreForIndexAccess": false}
}'

create_repo_if_missing "docker-group" "/service/rest/v1/repositories/docker/group" '{
  "name": "docker-group",
  "online": true,
  "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
  "group": {"memberNames": ["docker-hosted", "docker-proxy"]},
  "docker": {"v1Enabled": false, "forceBasicAuth": true, "httpPort": 8088}
}'

### 3. RBAC: least-privilege roles + service-account users #####################
create_role_if_missing "ci-deployer" '{
  "id": "ci-deployer",
  "name": "ci-deployer",
  "description": "CI pipelines: publish JAR/WAR + Docker artifacts, read the group repos",
  "privileges": [
    "nx-repository-view-maven2-maven-releases-add",
    "nx-repository-view-maven2-maven-releases-edit",
    "nx-repository-view-maven2-maven-releases-read",
    "nx-repository-view-maven2-maven-snapshots-add",
    "nx-repository-view-maven2-maven-snapshots-edit",
    "nx-repository-view-maven2-maven-snapshots-read",
    "nx-repository-view-maven2-maven-public-browse",
    "nx-repository-view-maven2-maven-public-read",
    "nx-repository-view-docker-docker-hosted-add",
    "nx-repository-view-docker-docker-hosted-edit",
    "nx-repository-view-docker-docker-hosted-read",
    "nx-repository-view-docker-docker-group-browse",
    "nx-repository-view-docker-docker-group-read"
  ],
  "roles": []
}'

create_role_if_missing "repo-readonly" '{
  "id": "repo-readonly",
  "name": "repo-readonly",
  "description": "Developers: read/pull only, no publish rights, no repository admin",
  "privileges": [
    "nx-repository-view-maven2-maven-public-browse",
    "nx-repository-view-maven2-maven-public-read",
    "nx-repository-view-docker-docker-group-browse",
    "nx-repository-view-docker-docker-group-read"
  ],
  "roles": []
}'

create_user_if_missing "jenkins-deployer" "{
  \"userId\": \"jenkins-deployer\",
  \"firstName\": \"Jenkins\",
  \"lastName\": \"Deployer\",
  \"emailAddress\": \"ci@buy01.local\",
  \"password\": \"${NEXUS_JENKINS_PASSWORD}\",
  \"status\": \"active\",
  \"roles\": [\"ci-deployer\"]
}"

create_user_if_missing "dev-readonly" "{
  \"userId\": \"dev-readonly\",
  \"firstName\": \"Dev\",
  \"lastName\": \"Readonly\",
  \"emailAddress\": \"dev@buy01.local\",
  \"password\": \"${NEXUS_READONLY_PASSWORD}\",
  \"status\": \"active\",
  \"roles\": [\"repo-readonly\"]
}"

log "done. Repositories, RBAC roles, and service-account users are provisioned."
log "Nexus UI: $NEXUS_URL  (admin / \$NEXUS_ADMIN_PASSWORD)"
