#!/bin/sh

echo "Starting install script"
cd /scripts

# https://hyperconverged-cluster-cli-download-openshift-cnv.apps.ocs.openshift.works/amd64/linux/virtctl.tar.gz
wget http://hyperconverged-cluster-cli-download.openshift-cnv.svc.cluster.local:8080/amd64/linux/virtctl.tar.gz -O /tmp/virtctl.tar.gz
tar -xzvf /tmp/virtctl.tar.gz -C /tmp/

${KC} apply -f windows-install-vm.yaml
echo "Applied VM"
sleep 5

/tmp/virtctl start windows-install
echo "Started VM, waiting for VM to start"
sleep 5

vm_ready=$(${KC} get vm windows-install -o jsonpath='{.status.ready}')
while [ "$vm_ready" != "true" ]
do
    sleep 10
    vm_ready=$(${KC} get vm windows-install -o jsonpath='{.status.ready}')
done

echo "VM is started. Waiting for VMI to finish successfully."
vmi_phase=$(${KC} get vmi windows-install -o jsonpath='{.status.phase}')
while [ "$vmi_phase" != "Succeeded" ]
do
    sleep 30
    vmi_phase=$(${KC} get vmi windows-install -o jsonpath='{.status.phase}')
    if [ "$vmi_phase" == "" ]; then
        vmi_phase="Succeeded"
    fi
done

echo "VM has finished installing"
${KC} apply -n ${IMAGES_NS} -f clone-boot-source.yaml
echo "Applied DataVolume to clone boot source image"

sleep 5
dv_phase=$(${KC} -n ${IMAGES_NS} get dv win2k19 -o jsonpath='{.status.phase}')
while [ "$dv_phase" != "Succeeded" ]
do
    sleep 10
    dv_phase=$(${KC} -n ${IMAGES_NS} get dv win2k19 -o jsonpath='{.status.phase}')
    echo $dv_phase
done

echo "Cleaning up"
${KC} delete -f windows-install-vm.yaml

my_app_name=$(${KC} get cm windows-install-scripts -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}')

echo "Finished"
