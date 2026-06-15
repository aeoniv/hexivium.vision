#!/usr/bin/env bash
# ============================================================================
# Qi Pipeline Director — GCP VM Provisioning
# ============================================================================
# Creates a single g2-standard-8 VM with 1× NVIDIA L4 (24 GB VRAM)
# Pre-loaded with the Deep Learning VM image (Ubuntu 22.04, CUDA 12.4)
#
# PREREQUISITES:
#   1. gcloud CLI authenticated:  gcloud auth login
#   2. Project exists:            gcloud projects describe hexivium-vision
#   3. GPU quota granted:         IAM & Admin > Quotas > NVIDIA_L4_GPUS (asia-east1)
#   4. GCS bucket created:        gsutil mb -l asia-east1 gs://hexivium-vision-pipeline
#   5. SMPL models uploaded:      gsutil cp -r ./smpl_data gs://hexivium-vision-pipeline/smpl_models/
#   6. Input files uploaded:      gsutil cp video.mp4 gs://hexivium-vision-pipeline/input/source_video.mp4
#                                 gsutil cp ref.png   gs://hexivium-vision-pipeline/input/reference_image.png
# ============================================================================

set -euo pipefail

PROJECT_ID="hexivium-vision"
ZONE="asia-southeast1-b"
INSTANCE_NAME="qi-pipeline-director"
MACHINE_TYPE="g2-standard-8"
BOOT_DISK_SIZE="300"
IMAGE_FAMILY="common-cu129-ubuntu-2204-nvidia-580"
IMAGE_PROJECT="deeplearning-platform-release"

# ── Provisioning model ──────────────────────────────────────────────────────
# Default to SPOT for ~60-70% cost savings. The pipeline checkpoints per stage,
# so a preemption is recoverable. Pass --on-demand for uninterruptible runs.
# SPOT requires automatic restart OFF; on-demand keeps restart-on-failure.
PROVISIONING_ARGS=(--provisioning-model=SPOT --instance-termination-action=STOP --no-restart-on-failure)
for arg in "$@"; do
    if [ "${arg}" = "--on-demand" ]; then
        PROVISIONING_ARGS=(--provisioning-model=STANDARD --restart-on-failure)
        echo "[i] On-demand (STANDARD) provisioning requested — no preemption, full price."
    fi
done

# ── Upload startup script to GCS (if not already there) ─────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[*] Uploading startup script to GCS..."
gsutil cp "${SCRIPT_DIR}/startup.sh" "gs://hexivium-vision-pipeline/scripts/startup.sh"

# ── Create the VM ────────────────────────────────────────────────────────────
echo "[*] Creating instance: ${INSTANCE_NAME} in ${ZONE}..."

gcloud compute instances create "${INSTANCE_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --maintenance-policy=TERMINATE \
    --accelerator=type=nvidia-l4,count=1 \
    --create-disk="auto-delete=yes,boot=yes,device-name=${INSTANCE_NAME},image-family=${IMAGE_FAMILY},image-project=${IMAGE_PROJECT},size=${BOOT_DISK_SIZE},type=pd-balanced" \
    --metadata=install-nvidia-driver=true,startup-script-url=gs://hexivium-vision-pipeline/scripts/startup.sh \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --labels=pipeline=qi-director,auto-shutdown=true \
    --tags=no-external-ingress \
    "${PROVISIONING_ARGS[@]}"

echo ""
echo "[✓] Instance created. Monitor startup progress:"
echo "    gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} -- 'tail -f /var/log/syslog | grep startup-script'"
echo ""
echo "[i] Once bootstrap completes, run the pipeline:"
echo "    gcloud compute ssh ${INSTANCE_NAME} --zone=${ZONE} --project=${PROJECT_ID} -- 'sudo bash /opt/qi-pipeline/run_pipeline.sh'"
