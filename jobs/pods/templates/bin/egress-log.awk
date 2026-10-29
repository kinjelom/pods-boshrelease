# Egress connection log of one pod (used by pod-supervisor every poll). Input: `nft -n list table inet pods_egress`.
# Appends one line per verdict, protocol, destination and port recorded by the log sets since the last poll to
# `logfile`; count = new connections (allowed) or blocked packets. Writes the nft commands deleting the logged
# elements to `deletefile`. Variables: time, prefix ("definition=<name> pod=<pod>"), logfile, deletefile.
# Plain POSIX awk: the stemcell's awk is mawk.
BEGIN {
  protocols[1] = "icmp"; protocols[6] = "tcp"; protocols[17] = "udp"; protocols[58] = "icmpv6"; protocols[132] = "sctp"
}

# record("<address> . <protocol> [. <port>] counter packets <n> bytes <n>")
function record(element,   key, count, fields, line) {
  if (element !~ / counter packets [0-9]+/) return
  key = element
  sub(/ counter packets .*/, "", key)
  gsub(/^[ \t]+|[ \t]+$/, "", key)
  count = element
  sub(/.* counter packets /, "", count)
  sub(/[^0-9].*/, "", count)
  split(key, fields, / \. /)
  line = time " " prefix " verdict=" verdict " proto=" (fields[2] in protocols ? protocols[fields[2]] : fields[2]) " dst=" fields[1]
  if (set !~ /_noport$/) line = line " dport=" fields[3]
  print line " count=" count >> logfile
  # not `set in keys`: mawk creates keys[set] before evaluating the right-hand side
  elements[set]++
  keys[set] = (elements[set] > 1 ? keys[set] ", " : "") key
}

$1 == "set" { set = ($2 ~ /^(allowed|blocked)[46](_noport)?$/) ? $2 : ""; verdict = set; sub(/[46].*/, "", verdict); next }
$1 == "chain" { set = ""; next }
set != "" && $1 == "size" { sizes[set] = $2 + 0 }
set != "" && /elements = \{/ { collecting = 1; sub(/.*elements = \{/, "") }
collecting {
  last = sub(/\}.*/, "")
  n = split($0, parts, ",")
  for (i = 1; i <= n; i++) record(parts[i])
  if (last) collecting = 0
}

END {
  for (set in keys) {
    print "delete element inet pods_egress " set " { " keys[set] " }" > deletefile
    # a full set records no new destinations until the next poll empties it
    if (sizes[set] > 0 && elements[set] >= sizes[set]) {
      verdict = set; sub(/[46].*/, "", verdict)
      print time " " prefix " verdict=" verdict " warning=\"log set " set " full (" sizes[set] " destinations within one poll), further destinations not logged\"" >> logfile
    }
  }
}
