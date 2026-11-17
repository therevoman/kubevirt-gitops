#!/bin/bash
# Repository checks, run by CI (.github/workflows/validate.yaml) and locally: hack/validate.sh
#  1. every kustomization builds (Components only build through what includes them)
#  2. every Application path exists; every ApplicationSet directory pattern matches something
#  3. the Windows build templates render for every winXX/base/os.env: valid XML/YAML, no
#     placeholders left
#  4. shellcheck on the build script (skipped if shellcheck is not installed)
# Needs bash, python3 with PyYAML, and kustomize (or oc/kubectl; set KUSTOMIZE to override).
set -u
cd "$(dirname "$0")/.." || exit 1
if [ -z "${KUSTOMIZE:-}" ]; then
  if command -v kustomize >/dev/null; then KUSTOMIZE="kustomize build"
  elif command -v oc >/dev/null; then KUSTOMIZE="oc kustomize"
  elif command -v kubectl >/dev/null; then KUSTOMIZE="kubectl kustomize"
  else echo "need kustomize, oc or kubectl"; exit 1; fi
fi
export KUSTOMIZE
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
err() { echo "FAIL: $*"; fail=1; }

echo "== kustomize build ($KUSTOMIZE)"
n=0
while read -r k; do
  d=$(dirname "$k")
  grep -q '^kind: Component' "$k" && continue
  n=$((n + 1))
  $KUSTOMIZE "$d" >"$TMP/out.yaml" 2>"$TMP/err" || { err "$d: $(grep -v -i warning "$TMP/err" | head -3)"; continue; }
  grep -i -q 'warning' "$TMP/err" && echo "warning in $d: $(grep -i warning "$TMP/err" | head -1)"
done < <(git ls-files --cached --others --exclude-standard '*kustomization.yaml' | sort)
echo "$n kustomizations built"

echo "== Argo CD health checks (gitopsservice/health)"
$KUSTOMIZE gitopsservice/health >"$TMP/health.yaml" 2>/dev/null || err "gitopsservice/health does not build"
grep -q 'FROM-LUA-FILE' "$TMP/health.yaml" && err "gitopsservice/health: a check was not filled from its .lua file"
echo "$(grep -c '^  - check:' "$TMP/health.yaml") checks"
if command -v luac >/dev/null; then
  for l in gitopsservice/health/*.lua; do luac -p "$l" || err "$l: Lua syntax"; done
else echo "luac not installed; Lua syntax not checked"; fi

echo "== Argo CD paths and example environment"
python3 - <<'PY' || fail=1
import glob, subprocess, sys, yaml, os

bad = 0; apps = 0; sets = 0
files = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '*.yaml'],
                       capture_output=True, text=True, check=True).stdout.split()
for f in files:
    try: docs = list(yaml.safe_load_all(open(f)))
    except Exception: continue
    for d in docs:
        if not isinstance(d, dict): continue
        if d.get('kind') == 'Application' and 'path' in d.get('spec', {}).get('source', {}):
            apps += 1; p = d['spec']['source']['path']
            if not os.path.isdir(p): print(f'FAIL: {f}: Application path {p} does not exist'); bad = 1
# Example environment: one overlay per Windows version, and the environment's ISO_BASE_URL must
# replace the placeholder in every install ISO URL (examples/environment, windows/environment)
base = yaml.safe_load(open('examples/environment/settings/settings.yaml'))['data']['ISO_BASE_URL']
for env in sorted(glob.glob('win*/base/os.env')):
    v = env.split('/')[0]; o = f'examples/environment/overlays/{v}'
    if not os.path.isdir(o): print(f'FAIL: {o} missing (every version needs an example overlay)'); bad = 1; continue
    out = subprocess.run(os.environ['KUSTOMIZE'].split() + [o], capture_output=True, text=True)
    urls = [d['spec']['source']['http']['url'] for d in yaml.safe_load_all(out.stdout)
            if d and d.get('kind') == 'DataVolume' and 'http' in d.get('spec', {}).get('source', {})]
    if not urls: print(f'FAIL: {o}: no install ISO DataVolume'); bad = 1
    for u in urls:
        if not u.startswith(base + '/windows/'): print(f'FAIL: {o}: ISO URL {u} does not start with {base}/windows/'); bad = 1
        else: sets += 1
print(f'{apps} Applications checked; {sets} example environment ISO URLs use ISO_BASE_URL')
sys.exit(bad)
PY

echo "== Windows build templates"
B=windows/build/config
sed -n '/^log()/p; /^check_params()/,/^}/p; /^subst()/,/^}/p; /^block()/,/^}/p; /^render()/,/^}/p' $B/install.sh > "$TMP/fns.sh"
for env in win*/base/os.env; do
  o=${env%%/*}; mkdir -p "$TMP/$o"
  bash -c "set -u; set -a; source <(grep -v '^#' '$env' | sed -E 's/^([A-Z_]+)=(.*)\$/\\1=\"\\2\"/'); set +a
    NAME=windows-\$OS-install; ISO_DV=\$BOOT_SOURCE-install-iso; CD_SECRET=\$NAME-cd
    VIRTIO_WIN_IMAGE=registry.example/virtio-win:test
    TARGET_DV=\$BOOT_SOURCE; SOURCE_NS=openshift-virtualization-os-images; SOURCE_PVC=\$BOOT_SOURCE-2026-12
    VERIFY_NAME=windows-\$OS-verify; VERIFY_SECRET=\$VERIFY_NAME-userdata
    VERIFY_SOURCE_NS=kubevirt-gitops; VERIFY_SOURCE_PVC=\$NAME-rootdisk
    PRODUCT_KEY=\${PRODUCT_KEY:-}; WU_MAX_ROUNDS=\${WU_MAX_ROUNDS:-8}
    [ \"\$BOOT_SOURCE\" = '$o' ] || { echo \"BOOT_SOURCE \$BOOT_SOURCE does not match directory $o\"; exit 1; }
    source '$TMP/fns.sh'; check_params
    render $B/autounattend.xml '$TMP/$o/autounattend.xml'
    render $B/windows-install-vm.yaml '$TMP/$o/vm.yaml'
    render $B/windows-verify-vm.yaml '$TMP/$o/verify-vm.yaml'
    render $B/clone-boot-source.yaml '$TMP/$o/clone.yaml'" || { err "$o: rendering failed"; continue; }
  python3 - "$TMP/$o" "$o" <<'PY' || err "$o: rendered templates are invalid"
import sys, yaml, xml.etree.ElementTree as ET
d, o = sys.argv[1:]
ns = {'u': 'urn:schemas-microsoft-com:unattend'}
x = ET.parse(f'{d}/autounattend.xml').getroot()
md = x.find('.//u:ImageInstall//u:MetaData', ns)
vm = yaml.safe_load(open(f'{d}/vm.yaml')); cl = yaml.safe_load(open(f'{d}/clone.yaml'))
ck = yaml.safe_load(open(f'{d}/verify-vm.yaml'))
assert vm['kind'] == 'VirtualMachine' and cl['kind'] == 'DataVolume' and ck['kind'] == 'VirtualMachine'
# The check VM must match the build VM's TPM (Windows 11 will not boot without it)
assert ('tpm' in vm['spec']['template']['spec']['domain']['devices']) == \
       ('tpm' in ck['spec']['template']['spec']['domain']['devices']), 'TPM differs between build and check VM'
assert cl['metadata']['name'] == o, cl['metadata']['name']
nic = vm['spec']['template']['spec']['domain']['devices']['interfaces'][0]['model']
print(f"{o}: {md.find('u:Key', ns).text}={md.find('u:Value', ns).text}, VM {vm['metadata']['name']}, NIC {nic}, boot source {o}")
PY
done

echo "== shellcheck"
if command -v shellcheck >/dev/null; then
  shellcheck -S warning -e SC2034 $B/install.sh hack/validate.sh || fail=1
else echo "shellcheck not installed; skipped"; fi

[ $fail = 0 ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit $fail
