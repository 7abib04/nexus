# Nexus Repository Manager for buy-01

A self-contained [Nexus Repository Manager 3](https://help.sonatype.com/en/sonatype-nexus-repository.html)
(OSS) instance that acts as the artifact store and dependency proxy for the
`backend/` Maven reactor and as the private Docker registry for every service
image — following the same "one dedicated stack per tool" pattern already
used by [`../sonarqube`](../sonarqube/README.md) and [`../jenkins`](../jenkins/README.md).

Repositories, RBAC roles, and service-account users are all provisioned by a
script ([`provision.sh`](provision.sh)) instead of by hand — re-running it is
safe and it's the source of truth for what's configured, rather than
one-off UI clicks nobody can reproduce.

## Contents

1. [Install & run Nexus](#1-install--run-nexus)
2. [Repositories](#2-repositories)
3. [Maven integration](#3-maven-integration)
4. [Dependency management through the Nexus proxy](#4-dependency-management-through-the-nexus-proxy)
5. [Versioning](#5-versioning)
6. [Docker integration](#6-docker-integration)
7. [CI/CD (Jenkins) integration](#7-cicd-jenkins-integration)
8. [Security & access control (RBAC)](#8-security--access-control-rbac)
9. [Stopping / resetting](#9-stopping--resetting)

## 1. Install & run Nexus

```sh
cd nexus
docker compose up -d
```

This uses the official `sonatype/nexus3` image, which already runs the Nexus
process as a **dedicated, non-root `nexus` user** (uid `200`) — never root.
Verify it yourself any time:

```sh
docker exec buy01-nexus id
# uid=200(nexus) gid=200(nexus) groups=200(nexus)
docker exec buy01-nexus ps aux
# USER    PID ... COMMAND
# nexus     1 ... .../java ... org.sonatype.nexus.karaf.NexusMain
```

First boot takes 1-2 minutes (Nexus bootstraps its OrientDB/H2 databases and
Elasticsearch index). `docker compose ps` shows `health: starting` until
`GET /service/rest/v1/status` returns `200`, then `healthy`.

- Nexus UI: http://localhost:8085 (mapped away from the default `8081` —
  that port is already buy-02's `user-service` on the host)
- Default login is `admin` with an auto-generated random password, written
  inside the container to `/nexus-data/admin.password` on first boot.

### Provision repositories, RBAC, and service accounts

```sh
./provision.sh
```

This one script (idempotent — safe to re-run after every `docker compose up`,
it checks before creating anything):

1. Waits for Nexus to report ready.
2. On first run only: reads the auto-generated admin password out of the
   container and rotates it to `$NEXUS_ADMIN_PASSWORD` (default
   `changeit-nexus-admin` — override it, e.g. `NEXUS_ADMIN_PASSWORD=... ./provision.sh`).
3. Creates the Maven repositories (§2).
4. Creates the Docker repositories (§2).
5. Creates two RBAC roles and two service-account users (§8).

```
[provision] waiting for Nexus at http://localhost:8085 to report STARTED...
[provision] Nexus is up.
[provision] first run detected (random initial admin password) - rotating it to NEXUS_ADMIN_PASSWORD
[provision] creating repository 'maven-central'
[provision] creating repository 'maven-releases'
[provision] creating repository 'maven-snapshots'
[provision] creating repository 'maven-public'
[provision] creating repository 'docker-hosted'
[provision] creating repository 'docker-proxy'
[provision] creating repository 'docker-group'
[provision] creating role 'ci-deployer'
[provision] creating role 'repo-readonly'
[provision] creating user 'jenkins-deployer'
[provision] creating user 'dev-readonly'
[provision] done. Repositories, RBAC roles, and service-account users are provisioned.
[provision] Nexus UI: http://localhost:8085  (admin / $NEXUS_ADMIN_PASSWORD)
```

_(screenshot: Nexus UI at http://localhost:8085/#browse/browse after
provisioning — the repository list on the left shows all seven repositories
below)_

## 2. Repositories

| Repository        | Type   | Format | Purpose                                                              |
|--------------------|--------|--------|------------------------------------------------------------------------|
| `maven-central`    | proxy  | maven2 | caches `https://repo1.maven.org/maven2/` — external Maven dependencies |
| `maven-releases`   | hosted | maven2 | buy-01's own release (non-`SNAPSHOT`) JARs                             |
| `maven-snapshots`  | hosted | maven2 | buy-01's own `-SNAPSHOT` JARs                                          |
| `maven-public`     | group  | maven2 | `maven-releases` + `maven-snapshots` + `maven-central`, one URL for Maven |
| `docker-hosted`    | hosted | docker | buy-01's own service + frontend images (port `8086`)                   |
| `docker-proxy`     | proxy  | docker | caches Docker Hub (port `8087`)                                        |
| `docker-group`     | group  | docker | `docker-hosted` + `docker-proxy`, one registry for pulls (port `8088`) |

All of this is declared in [`provision.sh`](provision.sh) — read it for the
exact REST payload (write policies, proxy remote URLs, group members, docker
connector ports) rather than clicking through the UI, since that's the
version that's actually reproducible.

_(screenshot: Administration → Repository → Repositories, showing the table
of all seven with type/format/status columns)_

## 3. Maven integration

[`backend/pom.xml`](../backend/pom.xml) declares where `mvn deploy` publishes to:

```xml
<properties>
    <nexus.url>http://localhost:8085</nexus.url>
</properties>

<distributionManagement>
    <repository>
        <id>nexus-releases</id>
        <url>${nexus.url}/repository/maven-releases/</url>
    </repository>
    <snapshotRepository>
        <id>nexus-snapshots</id>
        <url>${nexus.url}/repository/maven-snapshots/</url>
    </snapshotRepository>
</distributionManagement>
```

`nexus.url` defaults to the host-published port for local use and is
overridden with `-Dnexus.url=http://nexus:8081` in CI (Jenkins runs `mvn`
inside a container attached to the `buy01-nexusnet` Docker network, where the
Nexus container is reachable by its service name instead of the host port —
see [§7](#7-cicd-jenkins-integration)).

Credentials for those two `<id>`s come from [`settings.xml.template`](settings.xml.template),
**not** from the pom — copy it to `~/.m2/settings.xml` (or pass
`-s nexus/settings.xml.template` on every `mvn` invocation) and export:

```sh
export NEXUS_URL=http://localhost:8085
export NEXUS_DEPLOY_USER=jenkins-deployer
export NEXUS_DEPLOY_PASSWORD=changeit-jenkins-deployer   # or whatever ./provision.sh set it to
```

Maven interpolates `${env.NEXUS_DEPLOY_USER}` etc. in `settings.xml` the same
way it does `${...}` in `pom.xml`, so no password is ever hard-coded in a
committed file.

Publish every module's artifact:

```sh
cd backend
mvn -B -s ../nexus/settings.xml.template clean deploy -DskipTests
```

_(screenshot: Browse → maven-releases (or maven-snapshots) in the Nexus UI,
showing `com/buy01/product-service/...` with the deployed `.jar` and `.pom`)_

Confirm retrieval directly:

```sh
mvn dependency:get -s nexus/settings.xml.template \
  -Dartifact=com.buy01:product-service:0.0.1-SNAPSHOT -Dtransitive=false
```

## 4. Dependency management through the Nexus proxy

The same `settings.xml.template` mirrors **every** dependency and plugin
lookup through Nexus, not just deploys:

```xml
<mirrors>
    <mirror>
        <id>nexus</id>
        <mirrorOf>*</mirrorOf>
        <url>${env.NEXUS_URL}/repository/maven-public/</url>
    </mirror>
</mirrors>
```

`mirrorOf: *` means Maven never talks to `repo1.maven.org` directly once this
`settings.xml` is active — every `mvn` command (`test`, `package`, `deploy`,
...) resolves through `maven-public`, which serves cached artifacts from
`maven-central` (proxy) the first time and from Nexus's local blob store
every time after. Verify caching worked:

```sh
cd backend
mvn -s ../nexus/settings.xml.template -o dependency:resolve   # -o = offline, proves nothing is fetched from the internet
```

_(screenshot: Browse → maven-central in the Nexus UI after a build, showing
cached `.jar`s like `spring-boot-starter-web` that were fetched from Maven
Central once and are now served locally)_

## 5. Versioning

[`scripts/release.sh`](scripts/release.sh) bumps the reactor version with the
`versions-maven-plugin`, builds, and deploys every module in one step:

```sh
NEXUS_DEPLOY_USER=jenkins-deployer NEXUS_DEPLOY_PASSWORD=changeit-jenkins-deployer \
  ./nexus/scripts/release.sh 1.0.0
```

- A version **without** `-SNAPSHOT` (e.g. `1.0.0`) deploys to `maven-releases`,
  which uses `writePolicy: ALLOW_ONCE` — Nexus rejects overwriting an
  already-published release version, so published releases are immutable.
- A version **with** `-SNAPSHOT` (e.g. `1.1.0-SNAPSHOT`) deploys to
  `maven-snapshots`, which allows overwrites (`writePolicy: ALLOW`) since
  snapshots are expected to be replaced during active development.

Run it twice with different versions (e.g. `1.0.0` then `1.1.0-SNAPSHOT`) and
both are retrievable side by side:

```sh
mvn dependency:get -s nexus/settings.xml.template -Dartifact=com.buy01:product-service:1.0.0
mvn dependency:get -s nexus/settings.xml.template -Dartifact=com.buy01:product-service:1.1.0-SNAPSHOT
```

_(screenshot: Browse → maven-releases → com/buy01/product-service, with
multiple version folders listed — this is what "rollback" looks like: point
`distributionManagement`/a consumer's dependency version back at an older
folder that's still there, nothing was overwritten)_

Because `maven-releases` never allows overwrites, every release version ever
published stays retrievable forever — that's the traceability/rollback
story: a bad `1.2.0` doesn't erase `1.1.0`, so any environment can pin back
to it immediately.

## 6. Docker integration

[`scripts/docker-publish.sh`](scripts/docker-publish.sh) builds every backend
service image (same `backend/Dockerfile` + `SERVICE_MODULE` build arg the
root [`docker-compose.yml`](../docker-compose.yml) uses) plus the frontend
image, tags each with a version and `:latest`, and pushes both to
`docker-hosted`:

```sh
./nexus/scripts/docker-publish.sh 1.0.0
```

Manually, the same steps look like:

```sh
docker login localhost:8086 -u jenkins-deployer -p changeit-jenkins-deployer

docker build -f backend/Dockerfile --build-arg SERVICE_MODULE=gateway-service \
  -t localhost:8086/buy01/gateway-service:1.0.0 backend

docker push localhost:8086/buy01/gateway-service:1.0.0

docker pull localhost:8086/buy01/gateway-service:1.0.0   # confirms retrieval
```

`localhost:8086` needs no `daemon.json` "insecure registries" entry — Docker
automatically trusts any registry address that resolves to a loopback
address over plain HTTP, which is exactly what a locally published Nexus
port is.

_(screenshot: Browse → docker-hosted in the Nexus UI, showing
`buy01/gateway-service` with both the version tag and `latest`)_

To pull through the combined `docker-group` (hosted + Docker Hub proxy in one
registry, e.g. for a deployment host that shouldn't reach Docker Hub
directly):

```sh
docker login localhost:8088 -u dev-readonly -p changeit-dev-readonly
docker pull localhost:8088/buy01/gateway-service:1.0.0
docker pull localhost:8088/library/nginx:1.27-alpine   # served through docker-proxy
```

## 7. CI/CD (Jenkins) integration

The [`Jenkinsfile`](../Jenkinsfile) at the repo root now has two extra stages
that run whenever the `PUBLISH_TO_NEXUS` build parameter is `true` (default):

- **`Publish Artifacts to Nexus`** — runs after all backend/frontend tests
  and the SonarQube quality gate pass, before Docker images are built:
  `mvn -s nexus/settings.xml.template clean deploy -DskipTests`, using the
  `nexus-deploy-user` Jenkins credential.
- **`Docker Publish to Nexus`** — runs after `Build Docker Images`, when
  `RUN_DEPLOY` is also `true`: runs `nexus/scripts/docker-publish.sh` tagged
  with the build's short git commit SHA.

Both stages bind the `NEXUS_DEPLOY_USER`/`NEXUS_DEPLOY_PASSWORD` env vars via
`withCredentials` from a Jenkins **"Username with password"** credential
(id `nexus-deploy-user`, matching the `jenkins-deployer` service account —
see [§8](#8-security--access-control-rbac)) so no Nexus password is ever
written into the pipeline itself.

`nexus-deploy-user` is provisioned automatically by
[`jenkins/casc/jenkins.yaml`](../jenkins/casc/jenkins.yaml) from the
`NEXUS_JENKINS_USER`/`NEXUS_JENKINS_PASSWORD` env vars passed into the
Jenkins container (see [`jenkins/docker-compose.yml`](../jenkins/docker-compose.yml)) —
keep those in sync with whatever `./provision.sh` actually set:

```sh
cd nexus && docker compose up -d && ./provision.sh   # start Nexus first, its network must exist
cd ../jenkins
NEXUS_JENKINS_USER=jenkins-deployer NEXUS_JENKINS_PASSWORD=changeit-jenkins-deployer \
  docker compose up -d --build
```

Two different addresses are used for the same Nexus instance, and the
distinction matters:

- `NEXUS_URL` (Maven, `http://nexus:8081` by default) — `mvn` runs as a
  process **inside** the Jenkins container, so it needs the Nexus container's
  DNS name on the shared `buy01-nexusnet` Docker network (same pattern as
  `SONAR_HOST_URL=http://sonarqube:9000` on `buy01-sonarnet`, see
  [`jenkins/README.md`](../jenkins/README.md#6-sonarqube-quality-gate)).
- `NEXUS_DOCKER_REGISTRY` (Docker, `localhost:8086` by default) — `docker
  push` runs against the **host** Docker daemon (Jenkins reaches it through
  the bind-mounted `/var/run/docker.sock`, the same "Docker-outside-of-Docker"
  setup the existing `Deploy` stage already relies on), so it needs the
  host-published port, not the compose service name.

Trigger a build: Jenkins → **buy01-cicd** → **Build with Parameters**, leave
`PUBLISH_TO_NEXUS` checked. `pollSCM('H/2 * * * *')` (already configured)
also means every push to the watched branch triggers this automatically
within two minutes — build, test, and Nexus/Docker publish all happen without
manual intervention.

_(screenshot: Jenkins build console output showing the `Publish Artifacts to
Nexus` and `Docker Publish to Nexus` stages green)_

## 8. Security & access control (RBAC)

`admin` is never used for automated publishing. `./provision.sh` creates two
least-privilege roles and two matching users instead:

| User               | Role            | Privileges                                                                 |
|--------------------|-----------------|-------------------------------------------------------------------------------|
| `jenkins-deployer` | `ci-deployer`   | add/edit/read on `maven-releases`, `maven-snapshots`, `docker-hosted`; browse/read on `maven-public`, `docker-group` |
| `dev-readonly`     | `repo-readonly` | browse/read only on `maven-public`, `docker-group` — no publish rights anywhere |

Both roles are built from Nexus's own auto-generated per-repository
privileges (`nx-repository-view-<format>-<repo>-<action>`) rather than the
broad built-in `nx-admin`/`nx-deployment` roles, so:

- `jenkins-deployer` can publish to buy-01's own repos but can't touch
  `maven-central`/`docker-proxy` configuration, create/delete repositories,
  or manage users.
- `dev-readonly` can pull dependencies and images but can't push anything,
  anywhere — useful for a developer machine or a deploy-only host that
  should never be able to publish.

Change every default password before using this anywhere beyond your own
machine — `NEXUS_ADMIN_PASSWORD`, `NEXUS_JENKINS_PASSWORD`,
`NEXUS_READONLY_PASSWORD` env vars, passed to `./provision.sh`.

_(screenshot: Administration → Security → Roles, showing `ci-deployer` and
`repo-readonly` with their scoped privilege lists; Administration → Security
→ Users showing `jenkins-deployer` and `dev-readonly` alongside `admin`)_

Further hardening worth doing before any non-local use (not automated here
since it's account/environment-specific, same caveat as
[`sonarqube/README.md`](../sonarqube/README.md#6-permissions--access-control)'s
notification setup):

- Disable anonymous access (**Administration → Security → Anonymous Access**)
  — Nexus 3 ships with it **on** by default for read access.
- Rotate the three service passwords above periodically and after any leak.
- Put Nexus behind TLS (a reverse proxy, same as the frontend already does
  for the app itself) before exposing it outside `localhost`.

## Note on the Java version constraint

The project brief's constraint list says "Java 11 and a compatible Maven".
This repo's backend targets **Java 17** (`backend/pom.xml`'s `java.version`)
because it's built on **Spring Boot 3.3.5**, which requires Java 17 as its
minimum supported version — Spring Boot 3.x does not run on Java 11 at all.
Every Nexus/Maven/Docker/Jenkins piece here (JDK 17 base images, `mvn`
invocations) follows the codebase's actual, already-established Java version
rather than downgrading a working Spring Boot 3 reactor to an unsupported
runtime.

## 9. Stopping / resetting

```sh
docker compose down          # stop, keep all repositories/artifacts/users
docker compose down -v       # stop and wipe Nexus entirely (re-run provision.sh after)
```
