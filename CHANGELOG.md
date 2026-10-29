# Changelog

## 1.3.0 (2026-10-29)

### Added

- `pods`: egress connection log - `egress.log: none | blocked | all` per definition (default
  `pods.defaults.egress_log: blocked`). The rules record connections in dynamic nftables sets (destination, protocol,
  port, counter); every poll the supervisor moves them into `/var/vcap/sys/log/pods/<definition>/egress.log`, one line
  per pod, verdict, protocol, destination and port (`blocked`: blocked packets, `all`: also every new allowed
  connection, counted once per flow). No kernel logging (`nf_log_all_netns`) involved.
  See [docs/details.md](docs/details.md#connection-log).
- `pods` operator command (`/usr/local/bin/pods`, after `bosh ssh` + `sudo -i`): definitions with their monit
  process, pods and containers; `ps`, `logs`, `exec`, `describe`, `egress`, `restart`, `kube` per definition,
  bash completion in `/etc/profile.d/pods-bosh.sh` (`pods.shell_profile`, default true).

### Changed

- Definitions with `egress` now log blocked packets by default: set `egress.log: none` (or
  `pods.defaults.egress_log: none`) for the 1.2.0 behavior.

## 1.2.0 (2026-10-29)

### Changed

- podman-static 6.1.2 → 6.1.4.

### Added

- `pods`: `egress` per definition - an outbound traffic allowlist of the pods (`allow` entries by IP/CIDR,
  protocol `tcp`/`udp`/`icmp`/`all` and ports or port ranges, optional `dns` to the pod's nameservers).
  An nftables table (`inet pods_egress`, default drop) is loaded into each pod's network namespace before any of
  its containers, init containers included, starts: the pods are created stopped, the infra container is started,
  the rules are loaded through `nsenter`, then the pod is started. Loopback, replies to inbound connections
  (`hostPort` clients) and IPv6 neighbor discovery are always allowed, inbound traffic is not filtered.
  Blocked TCP connections are reset (refused at once), other blocked packets fail with `Operation not permitted`.
  See [docs/details.md](docs/details.md#egress-outbound-traffic).
- The rules fail closed: when they cannot be loaded the pods are torn down (monit retries, post-start fails the
  deploy); the supervisor reloads them when an infra container is restarted outside of it (`podman pod restart`).
- Pods that could bypass the rules are rejected: pre-start refuses `hostNetwork`, `play_flags` with
  `--network host`/`ns:`/`container:`, `privileged` containers and added `NET_ADMIN`, `NET_RAW`, `SYS_ADMIN` or
  `ALL` capabilities; before the start the supervisor checks the bounding capabilities of every container
  (also those granted through `podman.raw_config.containers_conf` `default_capabilities`).

### Notes

- Definitions without `egress` are started exactly as before.
- `egress` needs the `nft` and `nsenter` binaries on the stemcell (checked by pre-start).
- A pod restarted by hand runs without rules until the next supervisor poll (`pods.supervisor.poll_interval`):
  restart definitions with `monit restart pod-<definition>`.

## 1.1.0 (2026-10-26)

### Added

- `pods`: BOSH drain that stops every definition gracefully, dependents first. BOSH abandons a job stop after
  5 minutes (and e.g. deletes the VM of a recreate), but puts no time limit on a drain, so long
  `terminationGracePeriodSeconds` no longer end in SIGKILL.
- Pre-start rejects a `terminationGracePeriodSeconds` longer than the definition's `stop_timeout`.
- Grafana dashboard for the `podman-exporter` metrics ([docs/dashboard.json](docs/dashboard.json)).

## 1.0.1 (2026-09-27)

### Fixed

- `podman-exporter`: scrapes hung (`Limit of concurrent requests reached`) and podman's lock segment got
  corrupted - the exporter ran in local libpod mode (glibc) against the musl-built podman-static, whose pthread
  mutexes in `/dev/shm/libpod_lock` have a different layout. The job now runs `podman system service` (monit
  process `podman-exporter-api`, root-only socket) and the exporter is built without cgo as its API client.

## 1.0.0 (2026-09-26)

- First release: `podman`, `pods` (Kubernetes YAML via `podman kube play`, one monit process per definition)
  and `podman-exporter` jobs.
