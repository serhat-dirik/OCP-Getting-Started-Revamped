# Parasol Insurance - parasol-claims (Quarkus, JVM fast-jar)
#
# This is the SAME multi-stage build as the sibling `Containerfile`, kept under
# the `Dockerfile` name so tools that auto-detect a build recipe (for example
# `oc new-app --strategy=docker <repo>`, which looks for `Dockerfile` by default)
# find it with no extra configuration. `Containerfile` is the vendor-neutral name
# Red Hat uses; both are byte-for-byte the same build. If you edit one, edit both.
#
# Two stages, so build-time tools never reach production (a chained build):
#   * build stage   — a fat JDK 21 + Maven builder image; runs as root; discarded.
#   * runtime stage — a lean JRE-only image; runs as numeric non-root UID 185.
# Only the runtime stage ships, so the Maven cache and compiler stay out of the
# shipped image (fat builder in, lean runtime out).
#
# Base images pinned to the highest tag present in BOTH the builder and runtime
# streams (1.23) so the two stages stay matched and the build is reproducible.
#
# The runtime stage runs as numeric non-root UID 185 under OpenShift's
# restricted-v2 SCC (arbitrary UID, GID 0): the app writes nothing outside /tmp,
# and /deployments is owned by group 0 so an injected random UID can still read it.

## --- Build stage: JDK 21 + Maven (UBI9 builder image). Runs as root; discarded. ---
FROM registry.access.redhat.com/ubi9/openjdk-21:1.23 AS build
USER root
WORKDIR /build

COPY pom.xml ./
COPY src ./src

# Produce the Quarkus fast-jar under target/quarkus-app/. Tests run in CI, not here.
RUN mvn -B -ntp -DskipTests clean package

## --- Runtime stage: JRE-only UBI9 image, non-root. ---
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.23
ENV LANGUAGE='en_US:en'

# Copy the fast-jar layout in cache-friendly order (libs change least, app most).
# --chown=185:0 + group-readable perms keep the app runnable under any random UID.
COPY --from=build --chown=185:0 /build/target/quarkus-app/lib/      /deployments/lib/
COPY --from=build --chown=185:0 /build/target/quarkus-app/*.jar     /deployments/
COPY --from=build --chown=185:0 /build/target/quarkus-app/app/      /deployments/app/
COPY --from=build --chown=185:0 /build/target/quarkus-app/quarkus/  /deployments/quarkus/

EXPOSE 8080
USER 185

ENTRYPOINT [ "java", "-jar", "/deployments/quarkus-run.jar" ]
