## Pods BOSH Release

Run containers on BOSH VMs from **Kubernetes YAML** (Pod, Deployment, DaemonSet, ConfigMap, Secret,
PersistentVolumeClaim) - without Kubernetes, using daemonless [
`podman kube play`](https://docs.podman.io/en/latest/markdown/podman-kube-play.1.html).
Every pod definition is a separate monit process; container output goes to `/var/vcap/sys/log`.

Requires an **`ubuntu-noble`** stemcell (cgroup v2).

### Jobs

| Job               | Purpose                                                                                                |
|-------------------|--------------------------------------------------------------------------------------------------------|
| `podman`          | Podman engine configuration (no process).                                                              |
| `pods`            | Runs the Kubernetes YAML definitions: monit process `pod-<name>` each.                                 |
| `podman-exporter` | Prometheus metrics of containers, pods, images and volumes (`:9882/metrics`), read via the podman API. |

### Deployment

```yaml
jobs:
  - name: podman
    release: pods
  - name: pods
    release: pods
    properties:
      pods:
        definitions:
          redis:
            manifest:
              - apiVersion: v1
                kind: Pod
                metadata: { name: redis }
                spec:
                  containers:
                    - name: redis
                      image: docker.io/library/redis:7
                      ports: [ { containerPort: 6379, hostPort: 6379 } ]
```

Example: [example/manifests/pods.yml](example/manifests/pods.yml)
Details (how it works, logs, metrics, persistent data, limitations): [docs/details.md](docs/details.md).
Grafana dashboard for the `podman-exporter` metrics: [docs/dashboard.json](docs/dashboard.json).

### Development

```bash
./vendor-golang.sh           # golang-1.27-linux (needs an up-to-date bosh-package-golang-release clone)
./add-blobs.sh               # versions: src/meta-info/blobs-versions.env
./bosh-create-release.sh     # name/version/flags: rel.env
./bosh-upload-release.sh
bundle exec rspec            # template tests
```

### License

[MIT](LICENSE)
