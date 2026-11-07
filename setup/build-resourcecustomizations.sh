#!/bin/bash

MYPATH=$(cd "$(dirname "$0")" && pwd)

if [[ -z ${ARGO_NS:+isset} ]]
then
    A=($(kubectl get argocd -A | tail -n 1) )
    ARGO_NS=${A[0]}
    ARGO_CR=${A[1]}
fi
cd $MYPATH

cat <<EOF
apiVersion: argoproj.io/v1beta1
kind: ArgoCD
metadata:
  name: ${ARGO_CR}
  namespace: ${ARGO_NS}
spec:
  resourceHealthChecks: 
EOF

for lua in *.lua
do
#  echo $lua | awk -F_ '{print "    " $1 "/" $2 ":\n      " $3 ": |" }'
  echo $lua | awk -F_ '{print "    - group: " $1 "\n      kind: " $2 "\n      check: |" }'
  sed 's/^/        /' $lua
done
