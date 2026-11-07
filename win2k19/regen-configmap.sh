#!/bin/bash
cd "$(dirname "$0")"

oc -n kubevirt-gitops create cm windows-2k19-install-scripts --from-file=config --dry-run=client -o yaml > windows-install-scripts.yaml
