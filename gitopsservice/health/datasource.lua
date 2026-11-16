-- cdi.kubevirt.io/DataSource: Healthy when its Ready condition is True. A DataSource whose PVC
-- does not exist yet (a boot source still building) stays Progressing, not Degraded.
hs = { status = "Progressing", message = "Waiting for the DataSource to be Ready" }
if obj.status ~= nil and obj.status.conditions ~= nil then
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "Ready" then
      if c.status == "True" then
        hs.status = "Healthy"
        hs.message = c.message or "Ready"
      else
        hs.message = (c.reason or "NotReady") .. ": " .. (c.message or "")
      end
    end
  end
end
return hs
