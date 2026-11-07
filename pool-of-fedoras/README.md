### to show VirtualMachinePools
For demonstration scale up and down as needed.


# Scale the pool
oc scale vmpool vm-pool-fedora --replicas 1 -n pool-of-fedoras

oc scale vmpool vm-pool-fedora --replicas 15 -n pool-of-fedoras

oc scale vmpool vm-pool-fedora --replicas 3 -n pool-of-fedoras

# to show the endpoints changing
watch -n 0.5 curl -s --parallel --parallel-immediate --parallel-max 15 --config urls.txt

