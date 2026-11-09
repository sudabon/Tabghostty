package agentdetect

// Rollup returns the highest-priority state in blocked > working > idle > none.
// An empty collection is none.
func Rollup(states []State) State {
	var hasNone, hasIdle, hasWorking, hasBlocked bool
	for _, s := range states {
		switch s {
		case StateBlocked:
			hasBlocked = true
		case StateWorking:
			hasWorking = true
		case StateIdle:
			hasIdle = true
		case StateNone:
			hasNone = true
		}
	}
	switch {
	case hasBlocked:
		return StateBlocked
	case hasWorking:
		return StateWorking
	case hasIdle:
		return StateIdle
	case hasNone:
		return StateNone
	default:
		return StateNone
	}
}
