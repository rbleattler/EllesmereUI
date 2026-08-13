-- Does a straight reach at an arc child ever cross the parent's ICON box (the
-- only thing that armed the claim before), and does the claim's polar ground
-- hold that same reach (what arms it now)? Formulas taken from ChildGeom.
local pi, sin, cos, tan, abs, min, max = math.pi, math.sin, math.cos, math.tan,
    math.abs, math.min, math.max
local radius, iconSize, nestScale, band, gap = 100, 40, 0.8, 40, 10
local childIcon = iconSize * nestScale
local inner = radius + iconSize * 0.5 + childIcon * 0.5 + band

local function Report(entries, kids, spanDeg)
    local step = 2 * pi / entries
    local half = min(spanDeg * pi / 180 * 0.5, step * 0.5)
    half = max(half, step * 0.5)
    local angle = 0                      -- parent straight up
    local lo    = radius - iconSize * 0.5
    local edge  = radius + iconSize * 0.25
    local beam  = iconSize * 0.5
    local slope = tan(min(step * 0.5, pi / 3))
    local px, py = radius * sin(angle), radius * cos(angle)

    local crossed, onGround = 0, 0
    for j = 1, kids do
        local a = angle + (kids > 1 and (-half + (j - 1) * (2 * half / (kids - 1))) or 0)
        local cx, cy = inner * sin(a), inner * cos(a)
        -- (a) does the ray cross the parent's icon box?
        local hit = false
        for s = 1, 200 do
            local t = s / 200
            if abs(cx * t - px) <= iconSize * 0.5
               and abs(cy * t - py) <= iconSize * 0.5 then hit = true break end
        end
        -- (b) is the child's own position on the claim's polar ground?
        local u = cx * sin(angle) + cy * cos(angle)
        local v = abs(cx * cos(angle) - cy * sin(angle))
        local ground = false
        if u >= lo then
            if v <= beam + u * slope then ground = true
            elseif (cx * cx + cy * cy) ^ 0.5 >= edge then
                local ad = abs(a - angle)
                ground = ad <= half
            end
        end
        if hit then crossed = crossed + 1 end
        if ground then onGround = onGround + 1 end
    end
    print(("%2d entries, %2d children, span %d deg: reach crosses parent icon %d/%d, child on claim ground %d/%d")
        :format(entries, kids, spanDeg, crossed, kids, onGround, kids))
end

for _, e in ipairs({ 4, 6, 8, 12 }) do
    for _, k in ipairs({ 2, 4, 8 }) do Report(e, k, 90) end
end
