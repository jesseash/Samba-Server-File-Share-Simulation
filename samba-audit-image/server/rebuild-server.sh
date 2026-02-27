#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-local/samba-audit:latest}"
IMAGE_TAR="${IMAGE_TAR:-samba-audit-latest.tar}"
DEPLOYMENT="${DEPLOYMENT:-samba}"
NAMESPACE="${NAMESPACE:-default}"
APP_LABEL_KEY="${APP_LABEL_KEY:-app}"
APP_LABEL_VALUE="${APP_LABEL_VALUE:-$DEPLOYMENT}"
CONTAINER_INDEX="${CONTAINER_INDEX:-0}"

REFRESH_DEBS=false
OFFLINE_BUILD=false
NO_CACHE=true

case "${1:-}" in
  --refresh-debs) REFRESH_DEBS=true ;;
  --offline) OFFLINE_BUILD=true ;;
  --refresh-debs-offline)
    REFRESH_DEBS=true
    OFFLINE_BUILD=true
    ;;
  "") ;;
  *)
    echo "Usage:"
    echo "  $0                       # build+import+rollout (no-cache)"
    echo "  $0 --refresh-debs        # refresh minimal-debs then build"
    echo "  $0 --offline             # build with --network=none (prove local-only)"
    echo "  $0 --refresh-debs-offline# refresh debs then offline build"
    exit 2
    ;;
esac

echo "SERVER_DIR: ${SERVER_DIR}"
echo "IMAGE_NAME: ${IMAGE_NAME}"
echo "IMAGE_TAR: ${IMAGE_TAR}"
echo "DEPLOYMENT: ${DEPLOYMENT}"
echo "NAMESPACE: ${NAMESPACE}"
echo "LABEL: ${APP_LABEL_KEY}=${APP_LABEL_VALUE}"
echo "CONTAINER_INDEX: ${CONTAINER_INDEX}"
echo "REFRESH_DEBS: ${REFRESH_DEBS}"
echo "OFFLINE_BUILD: ${OFFLINE_BUILD}"
echo "NO_CACHE: ${NO_CACHE}"
echo

if [[ "${REFRESH_DEBS}" == "true" ]]; then
  echo "=== Step 0: Refreshing minimal-debs (downloads + Packages.gz) ==="
  pushd "${SERVER_DIR}/minimal-debs" >/dev/null
  ./download-minimal-debs.sh
  popd >/dev/null

  "${SERVER_DIR}/make-local-repo.sh"

  echo "=== Step 0.1: minimal-debs summary ==="
  ls -lah "${SERVER_DIR}/minimal-debs" | sed -n '1,200p'
fi

echo "=== Step 1: Removing old image from k3s containerd (if present) ==="
sudo k3s crictl rmi "${IMAGE_NAME}" >/dev/null 2>&1 || true
sudo k3s crictl rmi "docker.io/${IMAGE_NAME}" >/dev/null 2>&1 || true

echo "=== Step 2: Building server image ==="
cd "${SERVER_DIR}"

BUILD_ARGS=()
if [[ "${NO_CACHE}" == "true" ]]; then
  BUILD_ARGS+=(--no-cache)
fi
if [[ "${OFFLINE_BUILD}" == "true" ]]; then
  echo "=== Offline build enabled: docker build --network=none ==="
  BUILD_ARGS+=(--network=none)
fi

DOCKER_BUILDKIT=0 docker build -t "${IMAGE_NAME}" "${BUILD_ARGS[@]}" .

echo "=== Step 3: Exporting image tarball ==="
rm -f "${SERVER_DIR}/${IMAGE_TAR}"
docker save "${IMAGE_NAME}" -o "${SERVER_DIR}/${IMAGE_TAR}"
ls -lh "${SERVER_DIR}/${IMAGE_TAR}"

echo "=== Step 4: Importing into k3s containerd ==="
# Capture import output so we can tag whatever name containerd assigns back to ${IMAGE_NAME}.
IMPORT_OUT="$(sudo k3s ctr images import "${SERVER_DIR}/${IMAGE_TAR}" 2>&1 | tee /dev/stderr)"

echo "=== Step 4.0: Ensuring containerd tag matches exactly: ${IMAGE_NAME} ==="
# If containerd doesn't know ${IMAGE_NAME}, alias the imported ref to it.
if ! sudo k3s crictl inspecti "${IMAGE_NAME}" >/dev/null 2>&1; then
  # ctr import often prints: "<ref> saved"
  IMPORTED_REF="$(echo "${IMPORT_OUT}" | sed -n 's/^\(.*\) saved$/\1/p' | tail -n 1)"

  # Fallback: try the common normalization docker.io/${IMAGE_NAME}
  if [[ -z "${IMPORTED_REF}" ]]; then
    if sudo k3s crictl inspecti "docker.io/${IMAGE_NAME}" >/dev/null 2>&1; then
      IMPORTED_REF="docker.io/${IMAGE_NAME}"
    fi
  fi

  # Fallback: search containerd tags that end in "samba-audit:latest"
  if [[ -z "${IMPORTED_REF}" ]]; then
    IMPORTED_REF="$(sudo k3s ctr -n k8s.io images ls -q | grep -E '(^|/)samba-audit:latest$' | head -n 1 || true)"
  fi

  if [[ -z "${IMPORTED_REF}" ]]; then
    echo "❌ ERROR: Could not determine imported image reference to tag as ${IMAGE_NAME}"
    echo "Known containerd images matching 'samba-audit|local':"
    sudo k3s ctr -n k8s.io images ls | grep -E 'samba-audit|local' || true
    exit 1
  fi

  echo "Tagging imported image '${IMPORTED_REF}' as '${IMAGE_NAME}'..."
  sudo k3s ctr -n k8s.io images tag "${IMPORTED_REF}" "${IMAGE_NAME}"
fi

# Verify again (fail fast)
if ! sudo k3s crictl inspecti "${IMAGE_NAME}" >/dev/null 2>&1; then
  echo "❌ ERROR: After import/tag, image still not found in containerd as: ${IMAGE_NAME}"
  echo "Known containerd images matching 'samba-audit|local':"
  sudo k3s ctr -n k8s.io images ls | grep -E 'samba-audit|local' || true
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

echo "=== Step 5: Restarting deployment ==="
kubectl -n "${NAMESPACE}" rollout restart "deployment/${DEPLOYMENT}"

echo "=== Step 6: Waiting for rollout to complete (fail fast on bad pod states) ==="
ROLL_TIMEOUT="${ROLL_TIMEOUT:-240}"   # seconds
POLL_SECS="${POLL_SECS:-3}"

deadline=$((SECONDS + ROLL_TIMEOUT))
while (( SECONDS < deadline )); do
  # Get newest ReplicaSet for this deployment label
  NEW_RS="$(
    kubectl -n "${NAMESPACE}" get rs -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1].metadata.name}'
  )"

  if [[ -n "${NEW_RS}" ]]; then
    HASH="$(kubectl -n "${NAMESPACE}" get rs "${NEW_RS}" -o jsonpath='{.metadata.labels.pod-template-hash}' 2>/dev/null || true)"
    if [[ -n "${HASH}" ]]; then
      # Look for obvious failure states in the *new* RS pods
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

  # If rollout finished, stop waiting
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

echo "=== Step 7: Determining NEW ReplicaSet (by creation timestamp) ==="
NEW_RS="$(
  kubectl -n "${NAMESPACE}" get rs -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}'
)"
if [[ -z "${NEW_RS}" ]]; then
  echo "❌ ERROR: Could not determine NEW ReplicaSet"
  kubectl -n "${NAMESPACE}" get rs -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}"
  exit 1
fi
echo "New ReplicaSet: ${NEW_RS}"

echo "=== Step 8: Selecting newest pod from that ReplicaSet via pod-template-hash ==="
HASH="$(kubectl -n "${NAMESPACE}" get rs "${NEW_RS}" -o jsonpath='{.metadata.labels.pod-template-hash}')"
if [[ -z "${HASH}" ]]; then
  echo "❌ ERROR: Could not read pod-template-hash from rs/${NEW_RS}"
  kubectl -n "${NAMESPACE}" get rs "${NEW_RS}" -o yaml | sed -n '1,220p'
  exit 1
fi
echo "pod-template-hash: ${HASH}"

NEWEST_POD="$(
  kubectl -n "${NAMESPACE}" get pods -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE},pod-template-hash=${HASH}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}'
)"
if [[ -z "${NEWEST_POD}" ]]; then
  echo "❌ ERROR: Could not find pod for pod-template-hash=${HASH}"
  kubectl -n "${NAMESPACE}" get pods -l "${APP_LABEL_KEY}=${APP_LABEL_VALUE}" -o wide
  exit 1
fi
echo "Newest pod: ${NEWEST_POD}"

echo "=== Step 9: Waiting for newest pod to be Ready ==="
# bounded wait so it can't "hang"
if ! kubectl -n "${NAMESPACE}" wait --for=condition=ready "pod/${NEWEST_POD}" --timeout=120s; then
  echo "❌ ERROR: Newest pod did not become Ready in time."
  kubectl -n "${NAMESPACE}" describe pod "${NEWEST_POD}" | sed -n '1,260p' || true
  kubectl -n "${NAMESPACE}" logs "${NEWEST_POD}" --previous --tail=200 || true
  kubectl -n "${NAMESPACE}" logs "${NEWEST_POD}" --tail=200 || true
  exit 1
fi

echo "=== Step 10: Reading pod image and imageID ==="
POD_IMAGE="$(kubectl -n "${NAMESPACE}" get pod "${NEWEST_POD}" -o jsonpath="{.status.containerStatuses[${CONTAINER_INDEX}].image}")"
POD_IMAGE_ID="$(kubectl -n "${NAMESPACE}" get pod "${NEWEST_POD}" -o jsonpath="{.status.containerStatuses[${CONTAINER_INDEX}].imageID}")"
echo "POD_IMAGE:    ${POD_IMAGE}"
echo "POD_IMAGE_ID: ${POD_IMAGE_ID}"

if [[ -z "${POD_IMAGE_ID}" ]]; then
  echo "❌ ERROR: POD_IMAGE_ID is empty."
  kubectl -n "${NAMESPACE}" get pod "${NEWEST_POD}" -o yaml | sed -n '1,260p'
  exit 1
fi

echo "=== Step 11: Comparing digests ==="
POD_SHA="$(echo "${POD_IMAGE_ID}" | sed -n 's/.*@\(sha256:[0-9a-f]\+\).*/\1/p')"
if [[ -z "${POD_SHA}" ]]; then
  POD_SHA="$(echo "${POD_IMAGE_ID}" | sed -n 's/.*\(sha256:[0-9a-f]\+\).*/\1/p')"
fi
echo "POD_SHA: ${POD_SHA}"
echo "K3S_SHA: ${K3S_SHA}"

if [[ -z "${POD_SHA}" ]]; then
  echo "❌ ERROR: Could not parse sha256 digest from POD_IMAGE_ID: ${POD_IMAGE_ID}"
  exit 1
fi

if [[ "${POD_SHA}" == "${K3S_SHA}" ]]; then
  echo "✅ SUCCESS: Newest pod is running the image imported into k3s"
else
  echo "❌ ERROR: Newest pod is NOT running the image imported into k3s"
  echo "Hint: verify imagePullPolicy is IfNotPresent (or Never) and image name matches ${IMAGE_NAME}"
  exit 1
fi

echo "=== COMPLETE ==="
