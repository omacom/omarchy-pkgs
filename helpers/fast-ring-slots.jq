# The fast-ring catch-up's slots, in the publish record's shape, from
# bin/promote-channel --record lines read with jq -s.
#
# Each promote-channel run writes its whole plan, then one slot per batch;
# a plan line after a slot starts the next run. A slot's entries are the
# promoted files it carried, with the slot's own status. A promotion
# copies edge's file, so the size is edge's and the size it replaces is
# not known here. Lines of any other type are left out.
reduce .[] as $l ({plan: [], out: [], after_slot: false};
  if $l.type == "plan" then
    (if .after_slot then .plan = [] else . end) | .plan += [$l] | .after_slot = false
  elif $l.type == "slot" then
    .out += [($l | del(.type)) + {entries: [.plan[]
      | select(.action == "promote" and .arch == $l.arch)
      | (.file | sub("\\.pkg\\.tar\\.[^.]+$"; "")) as $stem
      | select($l.packages | index($stem))
      | {status: $l.status, file: $stem, name, base, version: .from_version, was: .to_version, size, was_size: null}]}]
    | .after_slot = true
  else . end)
| .out[]
