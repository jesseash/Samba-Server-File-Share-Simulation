#!/usr/bin/env bash
set -euo pipefail

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CLIENT_DIR}/.." && pwd)"

IMAGE_NAME="${IMAGE_NAME:-local/client:latest}"
IMAGE_TAR="${IMAGE_TAR:-client-latest.tar}"
DEPLOYMENT="${DEPLOYMENT:-samba-users}"
NAMESPACE="${NAMESPACE:-default}"
CLIENTS_MANIFEST="${CLIENTS_MANIFEST:-${REPO_ROOT}/k8s/clients-deployment.yaml}"
APP_LABEL_KEY="${APP_LABEL_KEY:-app}"
APP_LABEL_VALUE="${APP_LABEL_VALUE:-$DEPLOYMENT}"
CONTAINER_INDEX="${CONTAINER_INDEX:-0}"
OFFLINE_STRICT="${OFFLINE_STRICT:-1}"
HARD_COPY_DIR="${HARD_COPY_DIR:-${CLIENT_DIR}/minimal-debs-hard-copy}"
BASE_IMAGE_TAR="${BASE_IMAGE_TAR:-${REPO_ROOT}/ubuntu-base-image/ubuntu-24.04.tar}"
BASE_IMAGE_NAME="${BASE_IMAGE_NAME:-local/ubuntu-base:24.04}"

# You requested:
# - always refresh minimal-debs
# - always build offline (no network)
# - always no-cache
# - always scale to 10
TARGET_REPLICAS="${TARGET_REPLICAS:-10}"

echo "CLIENT_DIR: ${CLIENT_DIR}"
echo "IMAGE_NAME: ${IMAGE_NAME}"
echo "IMAGE_TAR: ${IMAGE_TAR}"
echo "DEPLOYMENT: ${DEPLOYMENT}"
echo "NAMESPACE: ${NAMESPACE}"
echo "CLIENTS_MANIFEST: ${CLIENTS_MANIFEST}"
echo "LABEL: ${APP_LABEL_KEY}=${APP_LABEL_VALUE}"
echo "CONTAINER_INDEX: ${CONTAINER_INDEX}"
echo "TARGET_REPLICAS: ${TARGET_REPLICAS}"
echo "OFFLINE_STRICT: ${OFFLINE_STRICT}"
echo "HARD_COPY_DIR: ${HARD_COPY_DIR}"
echo "BASE_IMAGE_TAR: ${BASE_IMAGE_TAR}"
echo "BASE_IMAGE_NAME: ${BASE_IMAGE_NAME}"
echo

load_base_image() {
  local import_out imported_ref

  echo "=== Step 0A: Loading Docker base image tar ==="
  if [[ ! -f "${BASE_IMAGE_TAR}" ]]; then
    echo "❌ ERROR: Base image tar not found: ${BASE_IMAGE_TAR}"
    exit 1
  fi

  import_out="$(docker load -i "${BASE_IMAGE_TAR}" 2>&1 | tee /dev/stderr)"

  imported_ref="$(echo "${import_out}" | sed -n 's/^Loaded image: \(.*\)$/\1/p' | tail -n 1)"
  if [[ -z "${imported_ref}" ]]; then
    imported_ref="$(echo "${import_out}" | sed -n 's/^Loaded image ID: \(sha256:[0-9a-f]\+\)$/\1/p' | tail -n 1)"
  fi

  if [[ -z "${imported_ref}" ]]; then
    echo "❌ ERROR: Could not determine loaded base image reference from ${BASE_IMAGE_TAR}"
    exit 1
  fi

  docker tag "${imported_ref}" "${BASE_IMAGE_NAME}"
  echo "Tagged base image '${imported_ref}' as '${BASE_IMAGE_NAME}'"
}

if [[ "${OFFLINE_STRICT}" == "1" ]]; then
  echo "=== Step 0: OFFLINE_STRICT=1 -> using local hard-copy debs only ==="
  if [[ ! -d "${HARD_COPY_DIR}" ]]; then
    echo "❌ ERROR: Hard-copy deb directory not found: ${HARD_COPY_DIR}"
    exit 1
  fi
  find "${CLIENT_DIR}/minimal-debs" -maxdepth 1 -type f ! -name 'download-minimal-debs.sh' -delete
  find "${HARD_COPY_DIR}" -maxdepth 1 -type f -exec cp -f {} "${CLIENT_DIR}/minimal-debs/" \;
else
  echo "=== Step 0: Refreshing minimal-debs (downloads + Packages.gz) ==="
  pushd "${CLIENT_DIR}/minimal-debs" >/dev/null
  ./download-minimal-debs.sh
  popd >/dev/null
fi

"${CLIENT_DIR}/make-local-repo.sh"

load_base_image

echo "=== Step 0.1: minimal-debs summary ==="
ls -lah "${CLIENT_DIR}/minimal-debs" | sed -n '1,200p'

echo "=== Step 1: Removing old image from k3s containerd (if present) ==="
sudo k3s crictl rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
sudo k3s crictl rmi "docker.io/${IMAGE_NAME}" >/dev/null 2>&1 || true

echo "=== Step 2: Building client image OFFLINE (no network, no cache) ==="
cd "${CLIENT_DIR}"

DOCKER_BUILDKIT=0 docker build \
  --no-cache \
  --network=none \
  --build-arg OFFLINE_BUILD=true \
  --build-arg BASE_IMAGE="${BASE_IMAGE_NAME}" \
  -t "${IMAGE_NAME}" .

echo "=== Step 3: Exporting image tarball ==="
rm -f "${CLIENT_DIR}/${IMAGE_TAR}"
docker save "${IMAGE_NAME}" -o "${CLIENT_DIR}/${IMAGE_TAR}"
ls -lh "${CLIENT_DIR}/${IMAGE_TAR}"

echo "=== Step 4: Importing into k3s containerd ==="
IMPORT_OUT="$(sudo k3s ctr images import "${CLIENT_DIR}/${IMAGE_TAR}" 2>&1 | tee /dev/stderr)"

echo "=== Step 4.0: Ensuring containerd tag matches exactly: ${IMAGE_NAME} ==="
if ! sudo k3s crictl inspecti "${IMAGE_NAME}" >/dev/null 2>&1; then
  IMPORTED_REF="$(echo "${IMPORT_OUT}" | sed -n 's/^\(.*\) saved$/\1/p' | tail -n 1)"

  if [[ -z "${IMPORTED_REF}" ]]; then
    if sudo k3s crictl inspecti "docker.io/${IMAGE_NAME}" >/dev/null 2>&1; then
      IMPORTED_REF="docker.io/${IMAGE_NAME}"
    fi
  fi

  if [[ -z "${IMPORTED_REF}" ]]; then
    IMPORTED_REF="$(sudo k3s ctr -n k8s.io images ls -q | grep -E '(^|/)client:latest$' | head -n 1 || true)"
  fi

  if [[ -z "${IMPORTED_REF}" ]]; then
    echo "❌ ERROR: Could not determine imported image reference to tag as ${IMAGE_NAME}"
    echo "Known containerd images matching 'client|local':"
    sudo k3s ctr -n k8s.io images ls | egrep 'client|local' || true
    exit 1
  fi

  echo "Tagging imported image '${IMPORTED_REF}' as '${IMAGE_NAME}'..."
  sudo k3s ctr -n k8s.io images tag "${IMPORTED_REF}" "${IMAGE_NAME}"
fi

if ! sudo k3s crictl inspecti "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "❌ ERROR: After import/tag, image still not found in containerd as: ${IMAGE_NAME}"
  echo "Known containerd images matching 'client|local':"
  sudo k3s ctr -n k8s.io images ls | egrep 'client|local' || true
  exit 1
fi

echo "=== Step 4.1: Determine imported image digest via crictl inspecti ==="
K3S_REPODIGEST="$(
  sudo k3s crictl inspecti -o json "${IMAGE_NAME}" \
    | sed -n 's/.*"repoDigests": \[\s*"\([^"]*\)".*/\1/p' \
    | head -n 1
)"
K3S_ID="$(
  sudo k3s crictl inspecti -o json "${IMAGE_NAME}" \
    | sed -n 's/.*"id": "\([^"]*\)".*/\1/p' \
    | head -n 1
)"
echo "K3S_REPODIGEST: ${K3S_REPODIGEST:-<empty>}"
echo "K3S_ID:         ${K3S_ID:-<empty>}"

K3S_SHA="$(echo "${K3S_REPODIGEST}" | sed -n 's/.*@\(sha256:[0-9a-f]\+\).*/\1/p')"
if [[ -z "${K3S_SHA}" ]]; then
  K3S_SHA="${K3S_ID}"
fi
if [[ -z "${K3S_SHA}" ]]; then
  echo "❌ ERROR: Could not determine k3s image digest for ${IMAGE_NAME}"
  exit 1
fi
echo "K3S_SHA: ${K3S_SHA}"

echo "=== Step 5: Scaling deployment/${DEPLOYMENT} to replicas=${TARGET_REPLICAS} ==="
if ! kubectl -n "${NAMESPACE}" get deployment "${DEPLOYMENT}" >/dev/null 2>&1; then
  echo "deployment/${DEPLOYMENT} not found. Recreating from manifest: ${CLIENTS_MANIFEST}"
  if [[ ! -f "${CLIENTS_MANIFEST}" ]]; then
    echo "❌ ERROR: Deployment manifest not found: ${CLIENTS_MANIFEST}"
    exit 1
  fi
  kubectl -n "${NAMESPACE}" apply -f "${CLIENTS_MANIFEST}"
fi
kubectl -n "${NAMESPACE}" scale "deployment/${DEPLOYMENT}" --replicas="${TARGET_REPLICAS}"

echo "=== Step 6: Restarting deployment ==="
kubectl -n "${NAMESPACE}" rollout restart "deployment/${DEPLOYMENT}"

echo "=== Step 7: Waiting for rollout to complete (fail fast on bad pod states) ==="
ROLL_TIMEOUT="${ROLL_TIMEOUT:-300}"   # seconds
POLL_SECS="${POLL_SECS:-3}"

deadline=$((SECONDS + ROLL_TIMEOUT))
while (( SECONDS < deadline )); do
  NEW_RS="$(
    kubectl -n "${NAMESPACE}" get rs -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}'
  )"

  if [[ -n "${NEW_RS}" ]]; then
    HASH="$(kubectl -n "${NAMESPACE}" get rs "${NEW_RS}" -o jsonpath='{.metadata.labels.pod-template-hash}' 2>/dev/null || true)"
    if [[ -n "${HASH}" ]]; then
      BAD_PODS="$(
        kubectl -n "${NAMESPACE}" get pods -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE},pod-template-hash=${HASH}" --no-headers 2>/dev/null \
          | awk '$3 ~ /(CrashLoopBackOff|Error|ImagePullBackOff|ErrImagePull|Completed)/ {print $1 ":" $3}'
      )"
      if [[ -n "${BAD_PODS}" ]]; then
        echo "❌ ERROR: New ReplicaSet ${NEW_RS} has failing pods:"
        echo "${BAD_PODS}"
        POD_NAME="$(echo "${BAD_PODS}" | head -n1 | cut -d: -f1)"
        echo "--- describe pod/${POD_NAME} ---"
        kubectl -n "${NAMESPACE}" describe pod "${POD_NAME}" | sed -n '1,260p' || true
        echo "--- logs (previous) pod/${POD_NAME} ---"
        kubectl -n "${NAMESPACE}" logs "${POD_NAME}" --previous --tail=200 || true
        echo "--- logs pod/${POD_NAME} ---"
        kubectl -n "${NAMESPACE}" logs "${POD_NAME}" --tail=200 || true
        exit 1
      fi
    fi
  fi

  if kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=5s >/dev/null; then
    kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=5s
    break
  fi

  sleep "${POLL_SECS}"
done

if ! kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOYMENT}" --timeout=1s >/dev/null; then
  echo "❌ ERROR: Rollout did not complete within ${ROLL_TIMEOUT}s. Debug info:"
  kubectl -n "${NAMESPACE}" get deploy "${DEPLOYMENT}" -o wide || true
  kubectl -n "${NAMESPACE}" get rs -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" --sort-by=.metadata.creationTimestamp -o wide || true
  kubectl -n "${NAMESPACE}" get pods -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" -o wide || true
  kubectl -n "${NAMESPACE}" describe deploy "${DEPLOYMENT}" | sed -n '1,260p' || true
  exit 1
fi

echo "=== Step 8: Determining NEW ReplicaSet (by creation timestamp) ==="
NEW_RS="$(
  kubectl -n "${NAMESPACE}" get rs -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}'
)"
echo "New ReplicaSet: ${NEW_RS}"

echo "=== Step 9: Selecting newest pod from that ReplicaSet via pod-template-hash ==="
HASH="$(kubectl -n "${NAMESPACE}" get rs "${NEW_RS}" -o jsonpath='{.metadata.labels.pod-template-hash}')"
echo "pod-template-hash: ${HASH}"

NEWEST_POD="$(
  kubectl -n "${NAMESPACE}" get pods -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE},pod-template-hash=${HASH}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | tail -n 1
)"
if [[ -z "${NEWEST_POD}" ]]; then
  echo "❌ ERROR: No pods found for new ReplicaSet rs=${NEW_RS} hash=${HASH}"
  kubectl -n "${NAMESPACE}" get rs "${NEW_RS}" -o wide || true
  kubectl -n "${NAMESPACE}" describe rs "${NEW_RS}" | sed -n '1,220p' || true
  kubectl -n "${NAMESPACE}" get pods -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" -o wide || true
  exit 1
fi
echo "Newest pod: ${NEWEST_POD}"

echo "=== Step 10: Waiting for newest pod to be Ready ==="
if ! kubectl -n "${NAMESPACE}" wait --for=condition=ready "pod/${NEWEST_POD}" --timeout=180s; then
  echo "❌ ERROR: Newest pod did not become Ready in time."
  kubectl -n "${NAMESPACE}" describe pod "${NEWEST_POD}" | sed -n '1,260p' || true
  kubectl -n "${NAMESPACE}" logs "${NEWEST_POD}" --previous --tail=200 || true
  kubectl -n "${NAMESPACE}" logs "${NEWEST_POD}" --tail=200 || true
  exit 1
fi

echo "=== Step 11: Reading pod image and imageID ==="
POD_IMAGE="$(kubectl -n "${NAMESPACE}" get pod "${NEWEST_POD}" -o jsonpath="{.status.containerStatuses[${CONTAINER_INDEX}].image}")"
POD_IMAGE_ID="$(kubectl -n "${NAMESPACE}" get pod "${NEWEST_POD}" -o jsonpath="{.status.containerStatuses[${CONTAINER_INDEX}].imageID}")"
echo "POD_IMAGE:    ${POD_IMAGE}"
echo "POD_IMAGE_ID: ${POD_IMAGE_ID}"

echo "=== Step 12: Comparing digests ==="
POD_SHA="$(echo "${POD_IMAGE_ID}" | sed -n 's/.*@\(sha256:[0-9a-f]\+\).*/\1/p')"
if [[ -z "${POD_SHA}" ]]; then
  POD_SHA="$(echo "${POD_IMAGE_ID}" | sed -n 's/.*\(sha256:[0-9a-f]\+\).*/\1/p')"
fi
echo "POD_SHA: ${POD_SHA}"
echo "K3S_SHA: ${K3S_SHA}"

if [[ "${POD_SHA}" == "${K3S_SHA}" ]]; then
  echo "✅ SUCCESS: Newest pod is running the image imported into k3s"
else
  echo "❌ ERROR: Newest pod is NOT running the image imported into k3s"
  exit 1
fi

echo "=== COMPLETE ==="