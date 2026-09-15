extends Node
## GameConfig - design-lock tunables (AGE-18 core-loop-spec v1.0).
## These seven values are BINDING. Drift requires a board gate (GDD scope fence).
## RekindleNode / PlayerController warn at _ready() if their local copies drift.

# --- design-lock tunables ---
const INTERACT_RANGE := 2.5
const KINDLE_TIME := 1.2
const PROPAGATION_TIERS := 3
const CARRY_STACK := 1
const DIM_TIME := 6.0
const CHECKPOINT_RADIUS := 6.0
const FAIL_RESET_MAX := 8.0

# --- v1 scope flags ---
const DIMMING_ENABLED := false  # DIMMING state ships in v2

# --- controller feel (greybox defaults, not design-locked) ---
const WALK_SPEED := 4.0
const RUN_SPEED := 7.0
const JUMP_VELOCITY := 5.2
const GRAVITY := 14.0
const CLIMB_SPEED := 3.0
const GLIDE_FALL_SPEED := 1.6


func tunables() -> Dictionary:
	return {
		"interact_range": INTERACT_RANGE,
		"kindle_time": KINDLE_TIME,
		"propagation_tiers": PROPAGATION_TIERS,
		"carry_stack": CARRY_STACK,
		"dim_time": DIM_TIME,
		"checkpoint_radius": CHECKPOINT_RADIUS,
		"fail_reset_max": FAIL_RESET_MAX,
	}
