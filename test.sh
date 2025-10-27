#!/bin/sh
i
echo "VM is started. Waiting for VMI to finish successfully."
vmi_phase=$(oc get vmi windows-install -o jsonpath='{.status.phase}')
while [ "$vmi_phase" != "Succeeded" ]
do
    sleep 3
    vmi_phase=$(oc get vmi windows-install -o jsonpath='{.status.phase}')
    echo phase=$vmi_phase
    if [ "$vmi_phase" == "" ]; then
        echo try2=$vmi_phase
    fi
done
