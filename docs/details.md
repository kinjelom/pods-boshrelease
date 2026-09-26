## Pods BOSH Release - details

* [How it works](#how-it-works)
* [Definitions](#definitions)
* [Logs](#logs)
* [Metrics](#metrics)
* [Persistent data](#persistent-data)
* [Configuration](#configuration)
* [Operating](#operating)
* [Known limitations / notes](#known-limitations--notes)

### How it works

```
monit ─ pod-ctl start <def> ─ setsid pod-supervisor <def>           (monit watches the supervisor pid)
                                ├─ podman kube play --replace kube.yml
                                ├─ poll `podman ps` every pods.supervisor.poll_interval seconds
                                │    pod gone / infra container stopped → exit → monit restarts the definition
                                ├─ tail -F <container k8s-file log> >> /var/vcap/sys/log/pods/<def>/<container>.log
                                └─ podman healthcheck run <container>   (liveness/startup probes)
monit ─ pod-ctl stop <def>  → SIGTERM → podman kube down (named volumes kept) → followers stopped
```

* **pre-start** (pods) validates and writes each definition to `/var/vcap/data/pods/definitions/<def>/`
  (`kube.yml`, mode 0600, may contain Secrets). Unsupported kinds (Service, Ingress, ...) are dropped and
  listed in the `kube.yml` header; Deployments must have 1 replica. Definitions removed from the manifest
  are cleaned up.
* **post-start** fails the deploy unless every pod is running (and healthy, when probes are defined)
  within `start_timeout`.
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
      stop_timeout: 60      # graceful teardown
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
`<definition>/pod-ctl.*.log`, `<definition>/supervisor.*.log`, podman events: `/var/vcap/sys/log/podman/events.log`.

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

The exporter reads podman's state with the podman libraries and takes the same (per-container) locks as
`podman ps`: keep the scrape interval >= 30s. It is stopped gracefully (SIGTERM, 45s) because a podman process
killed while holding a lock leaks that lock.

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

### Configuration

Each podman config file is generated from properties and can be extended/overridden with a raw hash that is
deep-merged over it (hashes merge recursively, other values replace, `null` removes a key):
`podman.raw_config.containers_conf`, `podman.raw_config.storage_conf`, `podman.raw_config.registries_conf`.
Registries: `podman.registries.{unqualified_search,insecure,mirrors,auth,policy}`. See `jobs/*/spec`.

### Operating

```bash
bosh ssh pods/0
sudo -i
podman ps --pod                    # PATH, auth and bash completion come from /etc/profile.d/podman-bosh.sh
monit summary                      # pod-<definition> processes
cat /var/vcap/data/pods/definitions/<def>/kube.yml
```

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

Podman binaries come from [mgoltzsche/podman-static](https://github.com/mgoltzsche/podman-static)
(podman, conmon, crun, runc, netavark, aardvark-dns, catatonit, pasta).
