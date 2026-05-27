# BEGIN add-pipeline block v3 — managed by /add-pipeline, do not edit by hand
# Always emits "fire" so the heartbeat schedule runs. Never emits a message
# override.
#
# CRITICAL: Trinity's pre-check API is agent-global — every scheduled skill on
# this agent (not just pipeline-tick) consults this same file. Two failure
# modes both silently hijack unrelated schedules:
#   1. Empty stdout silences ALL schedules on the agent.
#   2. Any non-"fire"/"skip" stdout becomes the message override applied to
#      WHICHEVER schedule called the pre-check — overwriting the intended
#      message of unrelated schedules (digests, heartbeats, batch jobs) and
#      making them run pipeline-tick instead of their own work.
# This block must therefore emit exactly "fire" and nothing else. Skip /
# work-detection logic belongs inside pipeline-tick itself, where it only
# affects pipeline-tick.
echo "fire"
# END add-pipeline block
