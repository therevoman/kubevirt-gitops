-- pool.kubevirt.io/VirtualMachinePool: Healthy when every replica is ready, Suspended when paused.
hs = { status = "Progressing", message = "No status available" }
if obj.spec ~= nil and obj.spec.paused == true then
  hs.status = "Suspended"
  hs.message = "Paused"
  return hs
end
if obj.status ~= nil then
  local want = 1
  if obj.spec ~= nil and obj.spec.replicas ~= nil then want = obj.spec.replicas end
  local ready = obj.status.readyReplicas or 0
  hs.message = ready .. "/" .. want .. " VMs ready"
  if ready >= want then hs.status = "Healthy" end
end
return hs
