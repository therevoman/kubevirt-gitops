#!/bin/bash
# Runs in the windows-<OS>-install Job and the monthly windows-<OS>-rebuild CronJob:
# build VM -> sysprep shutdown -> image check on a throwaway clone -> store the build as
# <BOOT_SOURCE>-<YYYY-MM> -> publish it as the boot source <BOOT_SOURCE> -> prune old builds.
# Shared by every Windows version; the parameters come from ConfigMap windows-<OS>-install-params
# (winXX/base/os.env) through envFrom.
# Idempotent: the Job (first build) exits 0 if the boot-source PVC already exists; both exit 0 if
# this month's build exists (delete it to build again).
#
# Fail fast: the Job exits non-zero as soon as the build is known to be broken, instead of waiting for
# activeDeadlineSeconds:
#  - the VM never starts reading the install ISO (CD boot prompt missed),
#  - the guest never reports status (Windows Setup stuck before post-install got the guest agent running),
#  - post-install/stage 2 reports FAILED in C:\Windows\Temp\build-status.txt,
#  - the status does not change for STALL_MIN minutes,
#  - the guest shuts down before sysprep started,
#  - the image check fails: a throwaway clone of the new disk must boot, start the guest agent and run
#    cloudbase-init user data before the boot source is published (VERIFY=false skips the check).
# On a failure the VM is left as it is for debugging; delete the Job and the VM to retry.
set -u

log() { echo "$(date -u +%H:%M:%S) $*"; }

# Required parameters, and the values the templates understand (hack/validate.sh runs this too)
check_params() {
  local v
  for v in OS BOOT_SOURCE OS_ID OS_NAME WORKLOAD EDITION DRIVER_DIR IMAGE_KEY IMAGE_VALUE TPM DISK_SIZE; do
    [ -n "${!v:-}" ] || { log "FAILED: parameter $v is not set (ConfigMap windows-<OS>-install-params, from winXX/base/os.env)"; exit 1; }
  done
  case "$EDITION" in desktop|server) ;; *) log "FAILED: EDITION must be desktop or server, not '$EDITION'"; exit 1 ;; esac
  case "$TPM" in true|false) ;; *) log "FAILED: TPM must be true or false, not '$TPM'"; exit 1 ;; esac
  case "$IMAGE_KEY" in /IMAGE/NAME|/IMAGE/INDEX) ;; *) log "FAILED: IMAGE_KEY must be /IMAGE/NAME or /IMAGE/INDEX"; exit 1 ;; esac
  [[ "$DISK_SIZE" =~ ^[0-9]+Gi$ ]] || { log "FAILED: DISK_SIZE must look like 60Gi, not '$DISK_SIZE'"; exit 1; }
}
check_params
PRODUCT_KEY=${PRODUCT_KEY:-}
AGENT_TIMEOUT_MIN=${AGENT_TIMEOUT_MIN:-60}   # VM start -> first status from the guest (Windows Setup + first logon)
STALL_MIN=${STALL_MIN:-150}                  # longest a single step (e.g. one Windows Update round) may take
WU_MAX_ROUNDS=${WU_MAX_ROUNDS:-8}            # Windows Update rounds before the build gives up
VERIFY=${VERIFY:-true}                       # check the new image on a throwaway clone before publishing
VERIFY_TIMEOUT_MIN=${VERIFY_TIMEOUT_MIN:-30} # clone + first boot (specialize, OOBE, cloudbase-init)
KEEP_BUILDS=${KEEP_BUILDS:-2}                # dated builds kept for rollback, including the new one
[[ "$KEEP_BUILDS" =~ ^[1-9][0-9]*$ ]] || { log "FAILED: KEEP_BUILDS must be 1 or more, not '$KEEP_BUILDS'"; exit 1; }
case "${JOB_NAME:-${HOSTNAME:-}}" in
  *-rebuild-*) MODE=rebuild ;;               # CronJob windows-<OS>-rebuild
  *) MODE=initial ;;                         # Job windows-<OS>-install (Argo CD PostSync hook)
esac

NAME=windows-$OS-install
ISO_DV=$BOOT_SOURCE-install-iso
IMAGES_NS=openshift-virtualization-os-images
BUILD_PVC=$BOOT_SOURCE-$(date -u +%Y-%m)   # this build, kept next to the boot source for rollback
CD_SECRET=$NAME-cd
NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)

cd /scripts || { log "FAILED: /scripts is not mounted"; exit 1; }

# Replace @KEY@ with a value in a file (the value may hold / | & characters)
subst() {  # <file> <KEY> <value>
  local v=${3//\\/\\\\}; v=${v//|/\\|}; v=${v//&/\\&}
  sed -i "s|@$2@|$v|g" "$1"
}
# Keep or drop the lines between "@IF_<BLOCK>@" and "@END_<BLOCK>@" markers
block() {  # <file> <BLOCK> <keep: true|false>
  if [ "$3" = true ]; then sed -i "/@IF_$2@/d; /@END_$2@/d" "$1"
  else sed -i "/@IF_$2@/,/@END_$2@/d" "$1"; fi
}
render() {  # <template> <output>: fill every build parameter, fail on any placeholder left over
  cp "$1" "$2"
  block "$2" TPM "$TPM"
  block "$2" DESKTOP "$([ "$EDITION" = desktop ] && echo true || echo false)"
  block "$2" PRODUCT_KEY "$([ -n "$PRODUCT_KEY" ] && echo true || echo false)"
  for v in NAME BOOT_SOURCE ISO_DV OS_ID OS_NAME WORKLOAD EDITION DRIVER_DIR IMAGE_KEY IMAGE_VALUE PRODUCT_KEY DISK_SIZE \
           WU_MAX_ROUNDS CD_SECRET VIRTIO_WIN_IMAGE TARGET_DV SOURCE_NS SOURCE_PVC \
           VERIFY_NAME VERIFY_SECRET VERIFY_SOURCE_NS VERIFY_SOURCE_PVC; do
    subst "$2" $v "${!v:-}"
  done
  if grep -n '@[A-Z_]*@' "$2"; then log "FAILED: unfilled placeholders in $2"; exit 1; fi
}

if [ $MODE = initial ] && oc get pvc $BOOT_SOURCE -n $IMAGES_NS >/dev/null 2>&1; then
  log "PVC $IMAGES_NS/$BOOT_SOURCE already exists; CronJob windows-$OS-rebuild refreshes it monthly. Nothing to do."
  exit 0
fi
if oc get pvc $BUILD_PVC -n $IMAGES_NS >/dev/null 2>&1; then
  log "This month's build $IMAGES_NS/$BUILD_PVC already exists; delete it to build again. Nothing to do."
  oc get pvc $BOOT_SOURCE -n $IMAGES_NS >/dev/null 2>&1 \
    || log "PVC $IMAGES_NS/$BOOT_SOURCE is missing: publish the build by hand (windows/build/README.md, Roll back)"
  exit 0
fi
if oc get vm $NAME -n $NS >/dev/null 2>&1; then
  log "FAILED: VM $NAME exists: a build is running, or an earlier one failed and was left for debugging. Delete it to build again."
  exit 1
fi
log "Building $OS_NAME ($EDITION, $MODE build) into $IMAGES_NS/$BUILD_PVC, published as $IMAGES_NS/$BOOT_SOURCE"

oc get dv $ISO_DV -n $NS >/dev/null 2>&1 \
  || { log "FAILED: DataVolume $ISO_DV is missing; sync the Argo CD Application to import the ISO again"; exit 1; }
log "Waiting for the ISO import (DataVolume $ISO_DV)"
oc wait dv/$ISO_DV -n $NS --for=condition=Ready --timeout=3600s || { log "ISO import failed"; exit 1; }

curl -sfk http://hyperconverged-cluster-cli-download.openshift-cnv.svc.cluster.local:8080/amd64/linux/virtctl.tar.gz -o /tmp/virtctl.tar.gz \
  && tar -xzf /tmp/virtctl.tar.gz -C /tmp/ || { log "virtctl download failed"; exit 1; }

# virtio-win image matching this CNV release. The fallback (when the CM is not readable) is pinned to
# the same minor release as the Job's ose-cli image; bump them together.
VIRTIO_WIN_IMAGE=$(oc get cm virtio-win -n openshift-cnv -o jsonpath='{.data.virtio-win-image}' 2>/dev/null)
VIRTIO_WIN_IMAGE=${VIRTIO_WIN_IMAGE:-registry.redhat.io/container-native-virtualization/virtio-win-rhel9:v4.22}
log "virtio-win image: $VIRTIO_WIN_IMAGE"

# The build VM's scripts CD: autounattend.xml with a random Administrator password for this build
# (never logged, deleted with the Secret when the Job ends), post-install.ps1, and its parameters.
mkdir -p /tmp/cd
render autounattend.xml /tmp/cd/autounattend.xml
cp post-install.ps1 /tmp/cd/
cat > /tmp/cd/build-params.ps1 <<EOF
\$DriverDir = '$DRIVER_DIR'
\$Edition = '$EDITION'
\$WuMaxRounds = $WU_MAX_ROUNDS
EOF
BUILD_PW="Bd-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)-7k"
sed -i "s|BUILD_ADMIN_PASSWORD|$BUILD_PW|g" /tmp/cd/autounattend.xml
unset BUILD_PW
oc create secret generic $CD_SECRET -n $NS --from-file=/tmp/cd --dry-run=client -o yaml | oc apply -f - >/dev/null \
  || { log "cannot create Secret $CD_SECRET"; exit 1; }
rm -rf /tmp/cd
VERIFY_NAME=windows-$OS-verify
VERIFY_SECRET=$VERIFY_NAME-userdata
# Both Secrets are only needed while this Job runs
trap 'oc delete secret $CD_SECRET $VERIFY_SECRET -n $NS --ignore-not-found >/dev/null' EXIT

render windows-install-vm.yaml /tmp/vm.yaml
oc apply -n $NS -f /tmp/vm.yaml || { log "cannot create VM $NAME"; exit 1; }

/tmp/virtctl start $NAME -n $NS
log "Started VM $NAME"
START=$(date +%s)

until [ "$(oc get vmi $NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do sleep 2; done
attach() {  # <vm>: point vexec, ga and guest_read at that VM's running virt-launcher pod
  POD=$(oc get pod -n $NS -l kubevirt.io/domain=$1 --field-selector=status.phase=Running -o name | head -1)
  DOM=${NS}_$1
}
attach $NAME
vexec() { oc exec -n $NS "$POD" -c compute -- "$@"; }
for n in 1 2 3 4 5; do vexec virsh domstate $DOM >/dev/null 2>&1 && break; sleep 1; done \
  || { log "cannot exec into $POD (SA needs 'use' on SCC kubevirt-controller); the CD boot prompt would time out"; vexec true; exit 1; }

# EFI shows "Press any key to boot from CD or DVD..." for a few seconds. Press "d" until the VM is
# reading the ISO in bulk, i.e. booting from it; stopping there keeps keys out of Windows Setup, where
# Space or Enter would press the focused button (Cancel) and a letter could trigger a hotkey.
ISO_DEV=$(vexec virsh domblklist $DOM | awk '/install-iso/ {print $1}')
# (if the ISO's device is not found, the totals for all disks work too: the blank root disk is barely read)
log "VMI running ($POD); pressing 'd' for the CD boot prompt (ISO device: ${ISO_DEV:-unknown, using all disks})"
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

# Image check (E1): boot a throwaway clone of the sysprepped disk, as a template clone would, and
# pass only when cloudbase-init ran this build's user data, i.e. specialize, OOBE, SetupComplete,
# the guest agent and cloudbase-init all work. A bad image is never published.
verify_image() {  # <source namespace> <source PVC>
  VERIFY_SOURCE_NS=$1 VERIFY_SOURCE_PVC=$2
  local nonce got st t0 agent=""
  nonce=$(tr -dc 'a-z0-9' </dev/urandom | head -c 16)
  # A check VM left by an earlier failed build is replaced
  oc delete vm $VERIFY_NAME -n $NS --ignore-not-found --wait=true >/dev/null
  oc delete dv $VERIFY_NAME-rootdisk -n $NS --ignore-not-found --wait=true >/dev/null
  oc create secret generic $VERIFY_SECRET -n $NS --dry-run=client -o yaml --from-literal=userdata="#ps1_sysnative
Set-Content -Path C:\\Windows\\Temp\\image-check.txt -Value 'image-check $nonce' -Encoding ASCII" | oc apply -f - >/dev/null \
    || { log "FAILED: cannot create Secret $VERIFY_SECRET"; exit 1; }
  render windows-verify-vm.yaml /tmp/verify-vm.yaml
  oc apply -n $NS -f /tmp/verify-vm.yaml >/dev/null || { log "FAILED: cannot create VM $VERIFY_NAME"; exit 1; }
  log "Image check: booting $VERIFY_NAME, a clone of $1/$2 (up to $VERIFY_TIMEOUT_MIN min)"
  t0=$(date +%s); POD=""
  while :; do
    if [ $(($(date +%s) - t0)) -gt $((VERIFY_TIMEOUT_MIN * 60)) ]; then
      if [ -z "$agent" ]; then log "FAILED: image check: the guest agent never answered (check the $VERIFY_NAME console)"
      else
        log "FAILED: image check: cloudbase-init did not run the user data. Last lines of its log:"
        guest_read "C:/Program Files/Cloudbase Solutions/Cloudbase-Init/log/cloudbase-init.log" 3000 | tail -25
      fi
      log "VM $VERIFY_NAME is left for debugging; the boot source was not published"
      exit 1
    fi
    case "$(oc get vmi $VERIFY_NAME -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" in
      Running) ;;
      Succeeded|Failed) log "FAILED: image check: $VERIFY_NAME stopped during its first boot"; exit 1 ;;
      *) sleep 15; continue ;;   # still cloning the disk or scheduling
    esac
    [ -n "$POD" ] || attach $VERIFY_NAME
    if [ -z "$agent" ] && ga '{"execute":"guest-ping"}' | grep -q return; then
      agent=1; log "Image check: guest agent answering after $((($(date +%s) - t0) / 60)) min"
    fi
    if [ -n "$agent" ]; then
      got=$(guest_read C:/Windows/Temp/image-check.txt | head -1)
      [ "$got" = "image-check $nonce" ] && break
    fi
    sleep 15
  done
  st=$(($(date +%s) - t0))
  log "Image check passed in $((st / 60)) min: the clone booted and cloudbase-init ran its user data"
  oc delete vm $VERIFY_NAME -n $NS --wait=false >/dev/null   # its DataVolume goes with it
  oc delete secret $VERIFY_SECRET -n $NS --ignore-not-found >/dev/null
}
if [ "$VERIFY" = true ]; then verify_image $NS $NAME-rootdisk
else log "VERIFY=$VERIFY: skipping the image check"; fi

clone() {  # <target DataVolume in IMAGES_NS> <source namespace> <source PVC>
  TARGET_DV=$1 SOURCE_NS=$2 SOURCE_PVC=$3
  render clone-boot-source.yaml /tmp/clone.yaml
  oc apply -f /tmp/clone.yaml >/dev/null || { log "FAILED: cannot create DataVolume $IMAGES_NS/$1"; exit 1; }
  log "Cloning $2/$3 to $IMAGES_NS/$1"
  oc wait dv/$1 -n $IMAGES_NS --for=condition=Ready --timeout=3600s || { log "FAILED: clone to $IMAGES_NS/$1"; exit 1; }
}

# Keep the build under its dated name (the rollback source), then publish it under the boot-source
# name the DataSource points at. The DataSource itself is not changed: SSP owns it.
clone $BUILD_PVC $NS $NAME-rootdisk
oc label pvc $BUILD_PVC -n $IMAGES_NS kubevirt-gitops/boot-source=$BOOT_SOURCE --overwrite >/dev/null
oc delete vm $NAME -n $NS --wait=false >/dev/null   # its root disk goes with it

if oc get pvc $BOOT_SOURCE -n $IMAGES_NS >/dev/null 2>&1; then
  # The DataSource is not Ready until the clone below finishes, so new VMs from the templates wait
  # for a few minutes; existing VMs have their own disks and are not affected.
  log "Replacing the previous $IMAGES_NS/$BOOT_SOURCE"
  oc delete dv,pvc $BOOT_SOURCE -n $IMAGES_NS --ignore-not-found --wait=true --timeout=30m >/dev/null \
    || { log "FAILED: cannot delete the previous $BOOT_SOURCE (still in use?); $BUILD_PVC is ready to publish"; exit 1; }
fi
clone $BOOT_SOURCE $IMAGES_NS $BUILD_PVC

# Prune: keep the newest KEEP_BUILDS dated builds of this boot source
oc get pvc -n $IMAGES_NS -l kubevirt-gitops/boot-source=$BOOT_SOURCE -o name | sed 's|.*/||' \
  | grep -E "^$BOOT_SOURCE-[0-9]{4}-[0-9]{2}\$" | sort -r | tail -n +$((KEEP_BUILDS + 1)) \
  | while read -r old; do
      log "Removing old build $IMAGES_NS/$old (KEEP_BUILDS=$KEEP_BUILDS)"
      oc delete dv,pvc "$old" -n $IMAGES_NS --ignore-not-found --wait=false >/dev/null
    done

log "Done: DataSource $BOOT_SOURCE now serves $BUILD_PVC. Keep DataVolume $ISO_DV: the monthly rebuild needs it."
