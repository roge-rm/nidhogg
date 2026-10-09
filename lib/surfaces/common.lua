-- Small helpers shared by the surface modules.

local common = {}

-- Calls fn now and, while held, again and again after a moment. Returns the
-- clock to cancel when let go of.
function common.hold(fn)
  fn()
  return clock.run(function()
    clock.sleep(0.35)
    while true do
      fn()
      clock.sleep(0.08)
    end
  end)
end

return common
