require 'base64'

describe 'pods job' do
  let(:redis_pod) do
    {
      'apiVersion' => 'v1', 'kind' => 'Pod', 'metadata' => { 'name' => 'redis' },
      'spec' => { 'containers' => [{ 'name' => 'redis', 'image' => 'docker.io/library/redis:7' }] },
    }
  end

  # decodes the files written by pre-start: { name => { 'kube' => ..., 'env' => ... } }
  def written_definitions(pre_start)
    pre_start.scan(/^write_definition (\S+) \\\n\s+'([^']*)' \\\n\s+'([^']*)'/).to_h do |name, kube, env|
      [name, { 'kube' => Base64.strict_decode64(kube), 'env' => Base64.strict_decode64(env) }]
    end
  end

  describe 'bin/pre-start' do
    it 'accepts a hash, a list and a multi-document string, dropping unsupported kinds' do
      helm_output = <<~YAML
        apiVersion: v1
        kind: Service
        metadata: { name: web }
        spec: { ports: [{ port: 80 }] }
        ---
        apiVersion: apps/v1
        kind: Deployment
        metadata: { name: web }
        spec:
          template:
            spec:
              containers: [{ name: nginx, image: nginx }]
      YAML
      pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => {
        'redis' => { 'manifest' => redis_pod, 'play_flags' => ['--network', 'host'], 'stop_timeout' => 5 },
        'cache' => { 'manifest' => [redis_pod.merge('metadata' => { 'name' => 'cache' })] },
        'web' => { 'manifest' => helm_output },
      } } })
      expect(bash_syntax_ok?(pre_start)).to be(true)

      defs = written_definitions(pre_start)
      expect(defs.keys).to contain_exactly('redis', 'cache', 'web')
      expect(defs['redis']['env']).to include('POD_NAMES=(redis)', 'PLAY_FLAGS=(--network host)', 'STOP_TIMEOUT=5', 'START_TIMEOUT=300')
      expect(defs['web']['env']).to include('POD_NAMES=(web-pod)', 'PLAY_FLAGS=()')
      expect(defs['web']['kube']).to include('# dropped (unsupported by podman kube play): Service/web')
      expect(YAML.load_stream(defs['web']['kube']).map { |d| d['kind'] }).to eq(['Deployment'])
      expect(pre_start).to include('DEFINITIONS=(redis cache web)')
    end

    describe 'hostPath ownership' do
      def host_path_owners(definition)
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'app' => definition } } })
        env = written_definitions(pre_start)['app']['env']
        _out, status = Open3.capture2('bash', '-n', stdin_data: env)
        raise 'invalid definition.env' unless status.success?
        out, = Open3.capture2('bash', '-c', env + "\nprintf '%s\\n' \"${HOST_PATH_OWNERS[@]}\"")
        out.split("\n")
      end

      def pod(containers, volumes, pod_security_context = nil)
        spec = { 'containers' => containers, 'volumes' => volumes }
        spec['securityContext'] = pod_security_context if pod_security_context
        { 'kind' => 'Pod', 'metadata' => { 'name' => 'app' }, 'spec' => spec }
      end

      let(:volumes) do
        [
          { 'name' => 'data', 'hostPath' => { 'path' => '/var/vcap/store/app/data/', 'type' => 'DirectoryOrCreate' } },
          { 'name' => 'logs', 'hostPath' => { 'path' => '/var/vcap/sys/log/app', 'type' => 'Directory' } },
          { 'name' => 'etc', 'hostPath' => { 'path' => '/etc/app', 'type' => 'DirectoryOrCreate' } },
          { 'name' => 'ro', 'hostPath' => { 'path' => '/var/vcap/store/app/ro', 'type' => 'DirectoryOrCreate' } },
          { 'name' => 'sock', 'hostPath' => { 'path' => '/var/vcap/data/app.sock', 'type' => 'Socket' } },
        ]
      end
      let(:mounts) do
        %w[data logs etc sock].map { |v| { 'name' => v, 'mountPath' => "/#{v}" } } +
          [{ 'name' => 'ro', 'mountPath' => '/ro', 'readOnly' => true }]
      end

      it 'derives owners from runAsUser/runAsGroup, only for writable directories below the allowed prefixes' do
        owners = host_path_owners('manifest' => pod(
          [{ 'name' => 'c', 'securityContext' => { 'runAsUser' => 13001, 'runAsGroup' => 13002 }, 'volumeMounts' => mounts }], volumes,
        ))
        expect(owners).to contain_exactly('/var/vcap/store/app/data|13001:13002|true', '/var/vcap/sys/log/app|13001:13002|false')
      end

      it 'uses the pod securityContext and a Deployment template, gid falls back to fsGroup and the uid' do
        deployment = { 'kind' => 'Deployment', 'metadata' => { 'name' => 'app' }, 'spec' => { 'template' => {
          'spec' => pod([{ 'name' => 'c', 'volumeMounts' => mounts }], volumes, { 'runAsUser' => 1000, 'fsGroup' => 2000 })['spec'],
        } } }
        expect(host_path_owners('manifest' => deployment)).to include('/var/vcap/store/app/data|1000:2000|true')
        expect(host_path_owners('manifest' => pod([{ 'name' => 'c', 'volumeMounts' => mounts }], volumes, { 'runAsUser' => 7 })))
          .to include('/var/vcap/store/app/data|7:7|true')
      end

      it 'leaves directories alone without runAsUser or when disabled' do
        root = pod([{ 'name' => 'c', 'volumeMounts' => mounts }], volumes)
        expect(host_path_owners('manifest' => root)).to eq([])
        user = pod([{ 'name' => 'c', 'securityContext' => { 'runAsUser' => 1 }, 'volumeMounts' => mounts }], volumes)
        expect(host_path_owners('manifest' => user, 'fix_host_path_ownership' => false)).to eq([])
      end

      it 'rejects conflicting owners unless host_path_owners decides' do
        containers = [
          { 'name' => 'a', 'securityContext' => { 'runAsUser' => 1 }, 'volumeMounts' => [{ 'name' => 'data', 'mountPath' => '/d' }] },
          { 'name' => 'b', 'securityContext' => { 'runAsUser' => 2 }, 'volumeMounts' => [{ 'name' => 'data', 'mountPath' => '/d' }] },
        ]
        expect { host_path_owners('manifest' => pod(containers, volumes)) }.to raise_error(/running as 1:1 \(a\) and 2:2 \(b\)/)
        expect(host_path_owners('manifest' => pod(containers, volumes), 'host_path_owners' => { '/var/vcap/store/app/data' => '3:3' }))
          .to eq(['/var/vcap/store/app/data|3:3|true'])
      end

      it 'rejects explicit owners outside the allowed prefixes' do
        expect {
          host_path_owners('manifest' => pod([], []), 'host_path_owners' => { '/var/vcap/store' => '1:1' })
        }.to raise_error(/not below/)
        expect {
          host_path_owners('manifest' => pod([], []), 'host_path_owners' => { '/var/vcap/store/../../etc' => '1:1' })
        }.to raise_error(/not below/)
      end
    end

    it 'rejects Deployments with more than one replica' do
      deployment = { 'kind' => 'Deployment', 'metadata' => { 'name' => 'x' }, 'spec' => { 'replicas' => 2 } }
      expect {
        render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'x' => { 'manifest' => deployment } } } })
      }.to raise_error(/2 replicas/)
    end

    it 'rejects manifests without pods and invalid names' do
      config_map = { 'kind' => 'ConfigMap', 'metadata' => { 'name' => 'c' } }
      expect {
        render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'x' => { 'manifest' => config_map } } } })
      }.to raise_error(/no Pod, Deployment or DaemonSet/)
      expect {
        render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'Bad_Name' => { 'manifest' => redis_pod } } } })
      }.to raise_error(/invalid name/)
    end
  end

  describe 'monit' do
    it 'renders one process per definition with dependencies and stop timeout' do
      monit = render('pods', 'monit', { 'pods' => { 'definitions' => {
        'db' => { 'manifest' => redis_pod },
        'app' => { 'manifest' => redis_pod, 'depends_on' => ['db'], 'stop_timeout' => 10,
                   'monit_additional_entries' => ['if totalmem > 90% for 5 cycles then restart'] },
      } } })
      expect(monit).to include('check process pod-db', 'check process pod-app')
      expect(monit).to include('stop program "/var/vcap/jobs/pods/bin/pod-ctl stop app" with timeout 40 seconds')
      expect(monit).to include('depends on pod-db', 'if totalmem > 90% for 5 cycles then restart')
    end

    it 'rejects unknown dependencies' do
      expect {
        render('pods', 'monit', { 'pods' => { 'definitions' => { 'app' => { 'manifest' => redis_pod, 'depends_on' => ['nope'] } } } })
      }.to raise_error(/unknown definition 'nope'/)
    end
  end

  it 'renders syntactically valid scripts' do
    props = { 'pods' => { 'definitions' => { 'redis' => { 'manifest' => redis_pod } } } }
    %w[bin/pre-start bin/post-start bin/pod-ctl bin/pod-supervisor bin/pods-env.sh].each do |template|
      expect(bash_syntax_ok?(render('pods', template, props))).to be(true)
    end
  end
end
