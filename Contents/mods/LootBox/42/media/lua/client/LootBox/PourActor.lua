local Actor = {}

-- Jog/sprint and the generic animation movement flag are not proof of a
-- local player's movement intent. Native player movement and input are.
local function moving(player)
    if player.pressedMovement and player:pressedMovement(false) then return true end
    if player.isPlayerMoving then return player:isPlayerMoving() end
    return player:isMoving()
end

function Actor.blocked(player)
    if not player:isLocalPlayer() or not player:getCurrentSquare() then return "Player is not ready." end
    if player:isDead() or player:isAsleep() then return "Character cannot act." end
    if player:isAiming() then return "Character is aiming." end
    if player:isAttacking() or player:isShoving() then return "Character is attacking or shoving." end
    if player:isClimbing() or player:isKnockedDown()
        or player.isbFalling and player:isbFalling()
        or player.isPerformingGrappleAnimation and player:isPerformingGrappleAnimation() then
        return "Character cannot safely pour in their current state."
    end
    if moving(player) then return "Character moved." end
end

return Actor
