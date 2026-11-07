#!/bin/bash
# Runs in the windows-2k19-install Job: build VM -> wait for sysprep shutdown -> clone to the win2k19 boot source.
# Idempotent: exits 0 if the boot-source PVC already exists (delete it to rebuild).
set -u
NAME=windows-2k19-install
ISO_DV=win2k19-install-iso
BOOT_SOURCE=win2k19
IMAGES_NS=openshift-virtualization-os-images
NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
cd /scripts

log() { echo "$(date -u +%H:%M:%S) $*"; }

if oc get pvc $BOOT_SOURCE -n $IMAGES_NS >/dev/null 2>&1; then
  log "PVC $IMAGES_NS/$BOOT_SOURCE already exists; delete it to rebuild. Nothing to do."
  exit 0
fi

log "Waiting for the ISO import (DataVolume $ISO_DV)"
oc wait dv/$ISO_DV -n $NS --for=condition=Ready --timeout=3600s || { log "ISO import failed"; exit 1; }

curl -sfk http://hyperconverged-cluster-cli-download.openshift-cnv.svc.cluster.local:8080/amd64/linux/virtctl.tar.gz -o /tmp/virtctl.tar.gz \
  && tar -xzf /tmp/virtctl.tar.gz -C /tmp/ || { log "virtctl download failed"; exit 1; }

# virtio-win image matching this CNV release (falls back to a release tag if the CM is not readable)
VIRTIO_IMG=$(oc get cm virtio-win -n openshift-cnv -o jsonpath='{.data.virtio-win-image}' 2>/dev/null)
VIRTIO_IMG=${VIRTIO_IMG:-registry.redhat.io/container-native-virtualization/virtio-win-rhel9:v4.22}
log "virtio-win image: $VIRTIO_IMG"
sed "s|VIRTIO_WIN_IMAGE|$VIRTIO_IMG|" windows-install-vm.yaml | oc apply -n $NS -f -

/tmp/virtctl start $NAME -n $NS
log "Started VM $NAME"

until [ "$(oc get vmi $NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do sleep 2; done
# EFI shows "Press any key to boot from CD or DVD..." for a few seconds: press it for the first 45s.
POD=$(oc get pod -n $NS -l kubevirt.io/domain=$NAME -o name | head -1)
log "VMI running ($POD); sending keys for the CD boot prompt"
for i in $(seq 1 45); do
  oc exec -n $NS "$POD" -c compute -- virsh send-key ${NS}_$NAME KEY_ENTER >/dev/null 2>&1
  sleep 1
done

log "Installing Windows; waiting for sysprep to shut the guest down (30-90 min)"
while :; do
  phase=$(oc get vmi $NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$phase" in
    Succeeded|"") break ;;
    Failed) log "VMI failed"; exit 1 ;;
  esac
  sleep 30
done
log "Guest shut down"

sed "s|BUILD_NAMESPACE|$NS|" clone-boot-source.yaml | oc apply -f -
log "Cloning the root disk to $IMAGES_NS/$BOOT_SOURCE"
oc wait dv/$BOOT_SOURCE -n $IMAGES_NS --for=condition=Ready --timeout=3600s || { log "clone failed"; exit 1; }

oc delete vm $NAME -n $NS --wait=false
log "Done: DataSource $BOOT_SOURCE should now be Ready. Deleting DataVolume $ISO_DV frees the ISO copy."
