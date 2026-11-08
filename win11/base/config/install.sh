#!/bin/bash
# Runs in the windows-11-install Job: build VM -> wait for sysprep shutdown -> clone to the win11 boot source.
# Idempotent: exits 0 if the boot-source PVC already exists (delete it to rebuild).
#
# Fail fast: the Job exits non-zero as soon as the build is known to be broken, instead of waiting for
# activeDeadlineSeconds:
#  - the VM never starts reading the install ISO (CD boot prompt missed),
#  - the guest never reports status (Windows Setup stuck before post-install got the guest agent running),
#  - post-install/stage 2 reports FAILED in C:\Windows\Temp\build-status.txt,
#  - the status does not change for STALL_MIN minutes,
#  - the guest shuts down before sysprep started.
# On a failure the VM is left as it is for debugging; delete the Job and the VM to retry.
set -u
NAME=windows-11-install
ISO_DV=win11-install-iso
BOOT_SOURCE=win11
IMAGES_NS=openshift-virtualization-os-images
CD_SECRET=windows-11-install-cd
AGENT_TIMEOUT_MIN=60      # VM start -> first status from the guest (Windows Setup + first logon)
STALL_MIN=150             # longest a single step (e.g. one Windows Update round) may take
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

# The build VM's scripts CD: autounattend.xml with a random Administrator password for this build
# (never logged, deleted with the Secret when the Job ends), plus post-install.ps1.
BUILD_PW="Bd-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)-7k"
mkdir -p /tmp/cd && cp autounattend.xml post-install.ps1 /tmp/cd/
sed -i "s|BUILD_ADMIN_PASSWORD|$BUILD_PW|g" /tmp/cd/autounattend.xml
unset BUILD_PW
oc create secret generic $CD_SECRET -n $NS --from-file=/tmp/cd --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || { log "cannot create Secret $CD_SECRET"; exit 1; }
rm -rf /tmp/cd
trap 'oc delete secret $CD_SECRET -n $NS --ignore-not-found >/dev/null' EXIT

# virtio-win image matching this CNV release (falls back to a release tag if the CM is not readable)
VIRTIO_IMG=$(oc get cm virtio-win -n openshift-cnv -o jsonpath='{.data.virtio-win-image}' 2>/dev/null)
VIRTIO_IMG=${VIRTIO_IMG:-registry.redhat.io/container-native-virtualization/virtio-win-rhel9:v4.22}
log "virtio-win image: $VIRTIO_IMG"
sed "s|VIRTIO_WIN_IMAGE|$VIRTIO_IMG|" windows-install-vm.yaml | oc apply -n $NS -f -

/tmp/virtctl start $NAME -n $NS
log "Started VM $NAME"
START=$(date +%s)

until [ "$(oc get vmi $NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do sleep 2; done
POD=$(oc get pod -n $NS -l kubevirt.io/domain=$NAME -o name | head -1)
DOM=${NS}_$NAME
vexec() { oc exec -n $NS "$POD" -c compute -- "$@"; }
for n in 1 2 3 4 5; do vexec virsh domstate $DOM >/dev/null 2>&1 && break; sleep 1; done \
  || { log "cannot exec into $POD (SA needs 'use' on SCC kubevirt-controller); the CD boot prompt would time out"; vexec true; exit 1; }

# EFI shows "Press any key to boot from CD or DVD..." for a few seconds. Press "d" until the VM is
# reading the ISO in bulk, i.e. booting from it; stopping there keeps keys out of Windows Setup, where
# Space or Enter would press the focused button (Cancel) and a letter could trigger a hotkey.
ISO_DEV=$(vexec virsh domblklist $DOM | awk '/install-iso/ {print $1}')
# (if the ISO's device is not found, the totals for all disks work too: the blank root disk is barely read)
log "VMI running ($POD); pressing "d" for the CD boot prompt (ISO device: ${ISO_DEV:-unknown, using all disks})"
booted=0
for i in $(seq 1 90); do
  rd=$(vexec virsh domblkstat $DOM $ISO_DEV 2>/dev/null | awk '$2 == "rd_bytes" {s += $3} END {print s + 0}')
  if [ "${rd:-0}" -gt 52428800 ]; then booted=1; break; fi
  vexec virsh send-key $DOM KEY_D >/dev/null 2>&1
  sleep 1
done
[ $booted = 1 ] || { log "FAILED: the VM did not boot from the install ISO within 90s (CD boot prompt missed?)"; exit 1; }
log "Booting from the install ISO ($((rd / 1048576)) MiB read)"

# Guest agent file read (empty output when the agent or the file is not there)
ga() { vexec virsh qemu-agent-command $DOM "$1" 2>/dev/null; }
guest_read() {  # <path with forward slashes> [<bytes from the end>]
  local h out
  h=$(ga "{\"execute\":\"guest-file-open\",\"arguments\":{\"path\":\"$1\",\"mode\":\"r\"}}" | sed -n 's/.*"return":\([0-9]*\).*/\1/p')
  [ -n "$h" ] || return 0
  [ -n "${2:-}" ] && ga "{\"execute\":\"guest-file-seek\",\"arguments\":{\"handle\":$h,\"offset\":-$2,\"whence\":\"end\"}}" >/dev/null
  out=$(ga "{\"execute\":\"guest-file-read\",\"arguments\":{\"handle\":$h,\"count\":${2:-4096}}}")
  ga "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$h}}" >/dev/null
  sed -n 's/.*"buf-b64":"\([^"]*\)".*/\1/p' <<<"$out" | base64 -d 2>/dev/null | tr -d '\r\000'
}

log "Installing Windows; following C:\\Windows\\Temp\\build-status.txt through the guest agent"
last=""; last_change=$START
while :; do
  phase=$(oc get vmi $NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
  case "$phase" in
    Succeeded|"") break ;;
    Failed) log "FAILED: VMI failed"; exit 1 ;;
  esac
  now=$(date +%s)
  st=$(guest_read C:/Windows/Temp/build-status.txt | head -1)
  if [ -n "$st" ] && [ "$st" != "$last" ]; then
    log "guest: $st"; last=$st; last_change=$now
    if [[ "$st" == *" FAILED "* ]]; then
      log "Build failed in the guest. Last lines of C:\\Windows\\Temp\\post-install.log:"
      guest_read C:/Windows/Temp/post-install.log 3000 | tail -25
      exit 1
    fi
  fi
  if [ -z "$last" ] && [ $((now - START)) -gt $((AGENT_TIMEOUT_MIN * 60)) ]; then
    log "FAILED: no status from the guest ${AGENT_TIMEOUT_MIN} min after start; Windows Setup or the first logon is stuck (check the VM console)"
    exit 1
  fi
  if [ -n "$last" ] && [ $((now - last_change)) -gt $((STALL_MIN * 60)) ]; then
    log "FAILED: build status unchanged for ${STALL_MIN} min: $last"
    exit 1
  fi
  sleep 15
done
[[ "$last" == *"sysprep running"* ]] || { log "FAILED: the guest shut down before sysprep started (last status: ${last:-none})"; exit 1; }
log "Guest shut down after sysprep"

sed "s|BUILD_NAMESPACE|$NS|" clone-boot-source.yaml | oc apply -f -
log "Cloning the root disk to $IMAGES_NS/$BOOT_SOURCE"
oc wait dv/$BOOT_SOURCE -n $IMAGES_NS --for=condition=Ready --timeout=3600s || { log "clone failed"; exit 1; }

oc delete vm $NAME -n $NS --wait=false
log "Done: DataSource $BOOT_SOURCE should now be Ready. Deleting DataVolume $ISO_DV frees the ISO copy."
