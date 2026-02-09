-- CAF_ModAPI/API.lua — Requireable API module
-- Usage: local caf = require("CAF_ModAPI/API")
--
-- CAF_ModAPI.lua must be loaded first (it is, alphabetically).
-- This module returns the global CAF table set by the main script.

if not CAF then
    log.info("[CAF/API] WARNING: CAF_ModAPI.lua has not loaded yet. API unavailable.")
    return {}
end

return CAF
