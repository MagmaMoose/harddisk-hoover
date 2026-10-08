# One image for both roles: the controller (kubectl) and the per-node cleanup (crictl,
# GNU find and coreutils, nsenter). Both binaries are fetched for the target platform and
# checked against the sha256 sums pinned below, which come from the upstream releases.
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS fetch

ARG TARGETARCH
ARG CRICTL_VERSION=v1.35.0
ARG CRICTL_SHA256_AMD64=2e141e5b22cb189c40365a11807d69b76b9b3caced89fac2f4ec879408ce2177
ARG CRICTL_SHA256_ARM64=519071de89b64c43e2a1661bb5489c6c3fd5e9e5fcef75e50e542b0c891f1118
ARG KUBECTL_VERSION=v1.35.9
ARG KUBECTL_SHA256_AMD64=3cfeaf80be482b435b0aa214aff6e0b2c312ee23c0ff20810c75517b6004c6eb
ARG KUBECTL_SHA256_ARM64=39c98bca82875d9a9ddfb6f3c5ab17c3f78ea0801230683e538a67d5c053308d

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache curl

RUN case "${TARGETARCH}" in \
      amd64) crictl_sum="${CRICTL_SHA256_AMD64}"; kubectl_sum="${KUBECTL_SHA256_AMD64}" ;; \
      arm64) crictl_sum="${CRICTL_SHA256_ARM64}"; kubectl_sum="${KUBECTL_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/crictl.tar.gz \
      "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    echo "${crictl_sum}  /tmp/crictl.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/crictl.tar.gz -C /usr/local/bin crictl; \
    curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "${kubectl_sum}  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/crictl /usr/local/bin/kubectl

FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Packages float within the pinned Alpine release, so security fixes arrive with each
# rebuild. GNU find (-printf, -regextype), coreutils (df --output, numfmt, date -d) and
# nsenter are what the cleanup needs beyond busybox.
# hadolint ignore=DL3018
RUN apk add --no-cache bash coreutils findutils jq util-linux-misc \
    && printf 'timeout: 60\n' > /etc/crictl.yaml

COPY --from=fetch /usr/local/bin/crictl /usr/local/bin/kubectl /usr/local/bin/
COPY --chmod=0755 src/hoover.sh /usr/local/bin/hoover
COPY --chmod=0755 src/controller.sh /usr/local/bin/hoover-controller

# The controller runs as this user. The cleanup pod needs root on the node and asks for
# it in its own securityContext (runAsUser: 0, privileged), which the chart sets.
USER 65532:65532

CMD ["/usr/local/bin/hoover-controller"]
