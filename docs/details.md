## Pods BOSH Release - details

* [How it works](#how-it-works)
* [Definitions](#definitions)
* [Logs](#logs)
* [Metrics](#metrics)
* [Persistent data](#persistent-data)
* [Egress (outbound traffic)](#egress-outbound-traffic)
* [Configuration](#configuration)
* [Operating](#operating)
* [Known limitations / notes](#known-limitations--notes)

### How it works

```
monit ─ pod-ctl start <def> ─ setsid pod-supervisor <def>           (monit watches the supervisor pid)
                                ├─ podman kube play --replace kube.yml
                                │    with egress: --start=false → start infra → nft rules in its netns → podman pod start
                                ├─ poll `podman ps` every pods.supervisor.poll_interval seconds
                                │    pod gone / infra container stopped → exit → monit restarts the definition
                                ├─ tail -F <container k8s-file log> >> /var/vcap/sys/log/pods/<def>/<container>.log
                                └─ podman healthcheck run <container>   (liveness/startup probes)
monit ─ pod-ctl stop <def>  → SIGTERM → podman kube down (named volumes kept) → followers stopped
drain ─ pod-ctl stop <def>  for every definition, dependents first (BOSH unmonitors the processes before)
```

* **pre-start** (pods) validates and writes each definition to `/var/vcap/data/pods/definitions/<def>/`
  (`kube.yml`, mode 0600, may contain Secrets). Unsupported kinds (Service, Ingress, ...) are dropped and
  listed in the `kube.yml` header; Deployments must have 1 replica. Definitions removed from the manifest
  are cleaned up.
* **post-start** fails the deploy unless every pod is running (and healthy, when probes are defined)
  within `start_timeout`. BOSH does not go on (next instance, next deploy) before that, so the `startupProbe`
  should check that the application is really ready (e.g. answers its API), not only that a port is open.
* **drain** stops the definitions gracefully before BOSH stops the jobs: BOSH puts no time limit on a drain, while
  it abandons its job stop after 5 minutes and carries on (e.g. deletes the VM of a recreate). Each definition gets
  `stop_timeout` (+15s) for `podman kube down`, which gives every container `terminationGracePeriodSeconds`
  (podman's stop timeout) before SIGKILL; pre-start rejects a grace period longer than `stop_timeout`.
* Container restarts (`restartPolicy`) are handled by podman/conmon; a failing `livenessProbe` restarts
  the container.

### Definitions

Each entry of `pods.definitions` is one monit process (`pod-<name>`, logs in `/var/vcap/sys/log/pods/<name>/`):

```yaml
pods:
  definitions:
    redis:
      depends_on: [ ]        # other definitions started first (monit dependency)
      start_timeout: 300    # post-start waits for running/healthy pods (includes image pulls)
      stop_timeout: 60      # graceful teardown (drain, monit stop), >= terminationGracePeriodSeconds
      manifest: # hash, list of hashes, or a multi-document YAML string (e.g. helm template output)
        - apiVersion: v1
          kind: Pod
          metadata: { name: redis }
          spec:
            containers:
              - name: redis
                image: docker.io/library/redis:7
                ports: [ { containerPort: 6379, hostPort: 6379 } ]
                volumeMounts: [ { name: data, mountPath: /data } ]
            volumes:
              - { name: data, hostPath: { path: /var/vcap/store/redis, type: DirectoryOrCreate } }
```

Supported kinds: Pod, Deployment and DaemonSet (1 replica), ConfigMap, Secret, PersistentVolumeClaim.
Credhub variables (`((name))`) can be used anywhere in the manifest, e.g. in `Secret` objects.
All keys and defaults: [jobs/pods/spec](../jobs/pods/spec).

### Logs

`/var/vcap/sys/log/pods/<definition>/<pod>-<container>.log` in CRI format (`<time> <stdout|stderr> <F|P> <line>`),
rotated by the stemcell logrotate, collected by `bosh logs` and syslog forwarders. Podman's internal copy is
capped by `podman.containers.log_size_max`. Script logs: `pre-start.*.log`, `post-start.*.log`,
`<definition>/pod-ctl.*.log`, `<definition>/supervisor.*.log`, podman events: `/var/vcap/sys/log/podman/events.log`,
outbound connections of definitions with `egress`: `<definition>/egress.log` (see [connection log](#connection-log)).

### Metrics

The `podman-exporter` job serves Prometheus metrics, e.g. `podman_container_state` (2 = running),
`podman_container_health` (0 = healthy, 1 = unhealthy, 2 = starting, -1 = unknown, e.g. no probe), CPU, memory,
network, block I/O, `podman_pod_state` (4 = running, 5 = degraded), image/volume sizes. With `enhance_metrics` (default)
every metric carries the container
`name` and `pod_name`; pod labels (`metadata.labels`) become metric labels via `whitelisted_labels` or `store_labels`.

For service discovery tag the deployment (see the example manifest):

```yaml
tags:
  prometheus_exporter_port: ((pods_exporter_port))
```

Grafana dashboard: [dashboard.json](dashboard.json) (import it; Grafana 12+). Overview (pods/containers not
running, unhealthy, restarts), pod and container tables with state/health timelines, CPU, memory (also against the
limit), processes, network per pod, block I/O, writable layer, images, volumes, podman/exporter versions.
Variables: `deployment` (the `bosh_deployment` target label, when the service discovery sets one), `instance`,
`pod`, `container`. It relies on `enhance_metrics: true` (default): the `name`/`pod_name` labels on all metrics.

The exporter is a client of a podman API service run by the same job: monit process `podman-exporter-api`
(`podman system service` on the root-only socket `/var/vcap/sys/run/podman-exporter/api/podman.sock`), logs in
`/var/vcap/sys/log/podman-exporter/`. The exporter links no podman libraries on purpose: libpod keeps its locks as
pthread mutexes in `/dev/shm/libpod_lock`, whose layout is libc specific, and the podman-static binaries use musl.
An exporter reading podman's state in-process (upstream "local mode", glibc) blocks forever on the first lock -
scrapes hang until `Limit of concurrent requests reached` - and corrupts the lock segment for podman.
Every scrape lists containers and pods through the API, taking the same locks as `podman ps`: keep the scrape
interval >= 30s.

### Persistent data

* `hostPath` under `/var/vcap/store/...` - explicit and recommended.
* **Ownership is handled by the release**: before every start (so also after a VM recreate, when directories on
  the ephemeral disk such as `/var/vcap/sys/log/<x>` come back empty and owned by root) the supervisor creates
  `DirectoryOrCreate` hostPaths and runs `chown -R uid:gid` on the ones mounted read-write by a container with
  `securityContext.runAsUser` (container or pod level; group: `runAsGroup` → `fsGroup` → uid) - only when the
  directory's owner differs, so large data directories are not walked on every start. For images with a non-root
  `USER`, declare it:
  ```yaml
  spec:
    securityContext: { runAsUser: 13001, runAsGroup: 13001 }   # e.g. jetbrains/youtrack
  ```
  Explicit owners: `host_path_owners: { /var/vcap/store/app: "1000:1000" }` in the definition; disable with
  `fix_host_path_ownership: false`. Only paths below `pods.host_paths.allowed_prefixes` (default `/var/vcap/store/`,
  `/var/vcap/data/`, `/var/vcap/sys/log/`, never the prefix itself; symlinks are resolved and re-checked) are touched.
* `PersistentVolumeClaim` - a podman named volume under `podman.data_dir` (persistent disk if present).
  Never removed by this release (`kube play --wait` is deliberately not used: its teardown deletes PVC volumes).

### Egress (outbound traffic)

`egress` restricts what the pods of a definition may connect to. Everything not listed is blocked:

```yaml
pods:
  definitions:
    app:
      egress:
        allow:
          - { to: 10.0.5.20, port: 5432 }                         # protocol: tcp (default)
          - { to: 10.0.6.0/24, protocol: udp, ports: [ 514, "6000-6010" ] }
          - { to: 10.0.7.1, protocol: icmp }
          - { to: "2001:db8::/32", protocol: all }                 # any protocol and port
        dns: true           # port 53 to the pod's nameservers (default false: names do not resolve)
        log: all            # connection log: none | blocked (default, pods.defaults.egress_log) | all
      manifest: [ ... ]
```

* `to`: an IPv4/IPv6 address or CIDR (host names are not resolved), `protocol`: `tcp` | `udp` | `icmp` | `all`,
  `port`/`ports`: required for tcp/udp, numbers or ranges. `allow: []` blocks every outbound connection.
* Always allowed: loopback (containers of the same pod), replies to inbound connections (clients of a `hostPort`,
  other pods), IPv6 neighbor discovery. Inbound traffic is not filtered.
* The rules apply to everything leaving the pod: the internet, other pods, the VM itself (its IPs, the bridge
  gateway). A blocked TCP connection is refused (reset), other blocked packets fail with `Operation not permitted`.
* `dns: true` allows DNS to the nameservers podman wrote into the pod's `/etc/resolv.conf` (aardvark-dns on the
  network gateway, or the VM's resolvers), so any name can be resolved, but only the listed addresses reached.

How: an nftables table `inet pods_egress` (output hook, default drop) in each pod's network namespace, loaded
with the stemcell's `nft` through `nsenter`. The supervisor creates the pods stopped (`kube play --start=false`),
starts the infra container (it owns the network namespace), loads the rules and only then starts the other
containers - init containers included - so no container ever runs without them. If the rules cannot be loaded,
the pods are torn down (monit retries, post-start fails the deploy).

The rules hold as long as no container can change or get around them. Pre-start rejects `hostNetwork`,
`play_flags` with `--network host` (or `ns:`/`container:`), `privileged` containers and added `NET_ADMIN`,
`NET_RAW`, `SYS_ADMIN` or `ALL` capabilities. Before the start, the supervisor also checks each container's
bounding capabilities, so these capabilities are caught even when they come from
`podman.raw_config.containers_conf` (`default_capabilities`).

Inspect the rules and the counters of blocked packets: `pods egress <definition>`, or by hand:

```bash
pid=$(podman ps --filter pod=<pod> --format '{{.IsInfra}} {{.Pid}}' | awk '$1 == "true" { print $2 }')
nsenter --target "$pid" --net nft list table inet pods_egress
```

#### Connection log

`egress.log` controls which outbound connections end up in `/var/vcap/sys/log/pods/<definition>/egress.log`
(rotated by the stemcell logrotate, collected by `bosh logs` and syslog forwarders like the other job logs):

| `log`               | logged                                                                  |
|---------------------|-------------------------------------------------------------------------|
| `none`              | nothing                                                                 |
| `blocked` (default) | packets blocked by the rules                                            |
| `all`               | every new outbound connection, allowed (DNS included) and blocked: audit |

The job-wide default is `pods.defaults.egress_log`. Every `pods.supervisor.poll_interval` the supervisor writes one
line per pod, verdict, protocol, destination and port seen since the previous poll:

```
2026-10-29T16:20:05+0000 definition=app pod=app verdict=allowed proto=tcp dst=10.0.5.20 dport=5432 count=2
2026-10-29T16:20:05+0000 definition=app pod=app verdict=blocked proto=tcp dst=203.0.113.7 dport=443 count=3
2026-10-29T16:20:05+0000 definition=app pod=app verdict=blocked proto=icmp dst=10.0.7.2 count=1
```

* `count`: allowed - new connections (a flow is counted once, by its first packet, also a UDP flow without
  replies); blocked - packets, i.e. failed attempts (`connect()` refused, `sendto()` with `Operation not permitted`).
* `dport` only for tcp/udp; `proto` is `tcp`, `udp`, `icmp`, `icmpv6`, `sctp` or the protocol number.
* The timestamp is when the line was written: the connections happened within the poll interval before it.
  Replies and packets of established connections are never logged, inbound connections neither.

How: the rules record each connection in dynamic nftables sets (`allowed4`, `blocked6_noport`, ... keyed by
destination, protocol and port, with a counter per element) - in the kernel, without `nf_log_all_netns` and without
a per-packet log. The supervisor lists the sets with `nft`, appends the lines (`bin/egress-log.awk`) and deletes the
logged elements. A set takes 4096 destinations per poll interval: beyond that a `warning="log set ... full"` line
says that further destinations were not logged. Packets counted between the listing and the deletion (milliseconds)
are missing from the counts, never a destination. The connections since the last poll are written on a stop too.

### Configuration

Each podman config file is generated from properties and can be extended/overridden with a raw hash that is
deep-merged over it (hashes merge recursively, other values replace, `null` removes a key):
`podman.raw_config.containers_conf`, `podman.raw_config.storage_conf`, `podman.raw_config.registries_conf`.
Registries: `podman.registries.{unqualified_search,insecure,mirrors,auth,policy}`. See `jobs/*/spec`.

### Operating

```bash
bosh ssh pods/0
sudo -i
pods                               # definitions: monit process, pods, containers (state, health)
pods logs <def> [-c <container>] -f --tail 100
pods exec <def> [-c <container>] [-- <command>]
pods describe <def>                # settings, files, containers; also: ps, egress, restart, kube (pods help)
podman ps --pod                    # PATH, auth and bash completion come from /etc/profile.d/podman-bosh.sh
monit summary                      # pod-<definition>, podman-exporter-api, podman-exporter processes
```

`pods` (`/usr/local/bin/pods`, root only) is a kubectl-like view of the definitions of the VM on top of podman and
monit - there is no Kubernetes API, so `kubectl` cannot be used. `<container>` is the name from the manifest (or
podman's `<pod>-<container>`) and may be omitted when only one container runs. Bash completion:
`/etc/profile.d/pods-bosh.sh` (`pods.shell_profile`).

### Known limitations / notes

* **Requires an `ubuntu-noble` stemcell** (cgroup v2): Podman 6 dropped cgroup v1, which Jammy stemcells use.
  The `podman` job pre-start fails the deploy with a clear message on a cgroup v1/hybrid host.
* One replica per Deployment, no Services/Ingress (use `hostPort` or `hostNetwork: true`).
* `httpGet` / `tcpSocket` probes are converted by podman into commands executed **inside** the container (`curl` / `nc`
  must exist in the image); `exec` probes work everywhere. `readinessProbe` is ignored.
* The static podman build has no systemd support, therefore probes are run by the pod supervisor (not by systemd
  timers). The supervisor polls, so probe timing has a `poll_interval` granularity.
* Netavark (Podman 6) only supports the `nftables` firewall driver - the `nft` binary must exist on the stemcell
  for bridge networking (`podman.network.firewall_driver: none` + `hostNetwork` otherwise).
* Definitions are meant for long-running services: a pod whose infra container stops is replayed by monit.
* Egress rules live in the pod's network namespace. A pod restarted by hand (`podman pod restart`, `podman start`)
  gets a new namespace: the supervisor reloads the rules on its next poll, so for up to `poll_interval` seconds
  the pod is unrestricted. Restart definitions with `monit restart pod-<definition>` instead.
* Stateful services (databases): give them a `terminationGracePeriodSeconds` long enough for a stop under load
  (migrations, compaction) - SIGKILL after the grace period is an unclean shutdown. Long grace periods are only
  safe through the drain: avoid `bosh stop/recreate --skip-drain`, BOSH stops waiting for `monit stop` after 5 minutes.
* A failing `startupProbe` (`failureThreshold` × `periodSeconds`) restarts the container: allow for the longest
  start (e.g. a database migration after an upgrade).

Podman binaries come from [mgoltzsche/podman-static](https://github.com/mgoltzsche/podman-static)
(podman, conmon, crun, runc, netavark, aardvark-dns, catatonit, pasta).
