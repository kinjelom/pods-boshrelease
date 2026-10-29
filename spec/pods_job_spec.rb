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

    describe 'egress' do
      # renders the definition and returns [EGRESS_RULES, EGRESS_DNS] as sourced by bash
      def egress(definition)
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'app' => { 'manifest' => redis_pod }.merge(definition) } } })
        env = written_definitions(pre_start)['app']['env']
        out, status = Open3.capture2('bash', '-c', env + "\nprintf '%s\\0%s' \"$EGRESS_RULES\" \"$EGRESS_DNS\"")
        raise 'invalid definition.env' unless status.success?
        out.split("\0", 2)
      end

      def pod_with(spec_overrides = {}, container_overrides = {})
        container = redis_pod['spec']['containers'][0].merge(container_overrides)
        redis_pod.merge('spec' => redis_pod['spec'].merge('containers' => [container]).merge(spec_overrides))
      end

      # loads the rules into a throw-away network namespace when the host allows it (unprivileged user namespaces)
      def nft_load(script)
        _out, status = Open3.capture2e('unshare', '-rn', 'nft', 'list', 'ruleset')
        return nil unless status.success?
        out, status = Open3.capture2e('unshare', '-rn', 'nft', '-f', '-', stdin_data: script)
        raise "nft rejected the rules: #{out}" unless status.success?
        true
      rescue Errno::ENOENT
        nil
      end

      it 'renders an allowlist with drop/reset as the default' do
        rules, dns = egress('egress' => { 'allow' => [
          { 'to' => '10.0.5.20', 'port' => 5432 },
          { 'to' => '10.0.6.7/24', 'protocol' => 'UDP', 'ports' => [514, '6000-6010', 514] },
          { 'to' => '2001:db8::/32', 'protocol' => 'all' },
          { 'to' => '10.0.7.1', 'protocol' => 'icmp' },
          { 'to' => '0.0.0.0/0', 'port' => 443 },
        ] })
        expect(dns).to eq('false')
        expect(rules).to start_with("table inet pods_egress\ndelete table inet pods_egress\n")
        expect(rules).to include(
          'type filter hook output priority filter; policy drop;', 'oifname "lo" accept', 'ct state established,related accept',
          'ip daddr 10.0.5.20 tcp dport { 5432 } accept', 'ip daddr 10.0.6.0/24 udp dport { 514, 6000-6010 } accept',
          'ip6 daddr 2001:db8::/32 accept', 'ip daddr 10.0.7.1 meta l4proto icmp accept', 'ip daddr 0.0.0.0/0 tcp dport { 443 } accept',
          'meta l4proto tcp counter reject with tcp reset', 'counter drop'
        )
        expect(rules).not_to include('dns4')
        loaded = nft_load(rules)
        skip 'nft in an unprivileged user namespace is not available' if loaded.nil?
        expect(loaded).to be(true)
      end

      it 'allows DNS through sets filled by the supervisor, an empty allowlist blocks everything else' do
        rules, dns = egress('egress' => { 'allow' => [], 'dns' => true })
        expect(dns).to eq('true')
        expect(rules).to include('set dns4 { type ipv4_addr; }', 'ip daddr @dns4 meta l4proto { tcp, udp } th dport 53 accept')
        expect(rules).not_to match(/daddr \d/)
        script = rules + "add element inet pods_egress dns4 { 10.89.0.1 }\nadd element inet pods_egress dns6 { fd00::1 }\n"
        loaded = nft_load(script)
        skip 'nft in an unprivileged user namespace is not available' if loaded.nil?
        expect(loaded).to be(true)
      end

      it 'is off without the key' do
        expect(egress({})).to eq(['', 'false'])
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'app' => { 'manifest' => redis_pod } } } })
        expect(pre_start).not_to include('nsenter')
      end

      it 'checks for nft and nsenter on the stemcell' do
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => {
          'app' => { 'manifest' => redis_pod, 'egress' => { 'allow' => [] } },
        } } })
        expect(bash_syntax_ok?(pre_start)).to be(true)
        expect(pre_start).to include('for tool in nft nsenter; do', "definition 'app': egress restricted to 0 allow rule(s)")
      end

      it 'rejects invalid allow entries' do
        {
          { 'to' => 'db.example.com', 'port' => 5432 } => /"db.example.com" is not an IP address or CIDR/,
          { 'to' => 'fe80::1%eth0', 'port' => 22 } => /"fe80::1%eth0" is not an IP address/,
          { 'to' => '10.0.0.1' } => /port or ports required for tcp/,
          { 'to' => '10.0.0.1', 'protocol' => 'icmp', 'port' => 1 } => /protocol icmp takes no ports/,
          { 'to' => '10.0.0.1', 'protocol' => 'sctp', 'port' => 1 } => /"sctp" is not tcp, udp, icmp or all/,
          { 'to' => '10.0.0.1', 'port' => 70000 } => /invalid port "70000"/,
          { 'to' => '10.0.0.1', 'ports' => ['90-80'] } => /invalid port "90-80"/,
          { 'to' => '10.0.0.1', 'port' => 1, 'ports' => [2] } => /either port or ports/,
          { 'to' => '10.0.0.1', 'port' => 1, 'proto' => 'udp' } => /allow\[0\]: unknown key\(s\) proto/,
        }.each do |entry, error|
          expect { egress('egress' => { 'allow' => [entry] }) }.to raise_error(error)
        end
        expect { egress('egress' => { 'allow' => [], 'log' => true }) }.to raise_error(/egress: unknown key\(s\) log/)
        expect { egress('egress' => [{ 'to' => '10.0.0.1' }]) }.to raise_error(/egress: must be a hash/)
      end

      it 'rejects pods that share the host network or could bypass the rules' do
        allow_none = { 'allow' => [] }
        expect { egress('manifest' => pod_with('hostNetwork' => true), 'egress' => allow_none) }.to raise_error(/uses hostNetwork/)
        expect { egress('egress' => allow_none, 'play_flags' => ['--network', 'host']) }.to raise_error(/network 'host'/)
        expect { egress('egress' => allow_none, 'play_flags' => ['--net=ns:/proc/1/ns/net']) }.to raise_error(%r{network 'ns:/proc/1/ns/net'})
        expect { egress('manifest' => pod_with({}, 'securityContext' => { 'privileged' => true }), 'egress' => allow_none) }
          .to raise_error(/container redis is privileged/)
        expect { egress('manifest' => pod_with({}, 'securityContext' => { 'capabilities' => { 'add' => ['cap_net_raw', 'CHOWN'] } }), 'egress' => allow_none) }
          .to raise_error(/container redis adds NET_RAW/)
        expect(egress('egress' => allow_none, 'play_flags' => ['--network', 'bridge']).first).to include('policy drop')
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

    it 'rejects a terminationGracePeriodSeconds longer than stop_timeout' do
      graceful = ->(grace) { redis_pod.merge('spec' => redis_pod['spec'].merge('terminationGracePeriodSeconds' => grace)) }
      expect {
        render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'x' => { 'manifest' => graceful.call(61) } } } })
      }.to raise_error(%r{Pod/redis terminationGracePeriodSeconds \(61\) exceeds stop_timeout \(60\)})
      deployment = { 'kind' => 'Deployment', 'metadata' => { 'name' => 'web' },
                     'spec' => { 'template' => { 'spec' => graceful.call(300)['spec'] } } }
      expect {
        render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'x' => { 'manifest' => deployment, 'stop_timeout' => 299 } } } })
      }.to raise_error(%r{Deployment/web terminationGracePeriodSeconds \(300\)})
      pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => {
        'x' => { 'manifest' => graceful.call(600), 'stop_timeout' => 600 },
      } } })
      expect(written_definitions(pre_start)['x']['env']).to include('STOP_TIMEOUT=600')
    end
  end

  describe 'bin/drain' do
    it 'stops dependents before their dependencies and reports 0 on the original stdout' do
      drain = render('pods', 'bin/drain', { 'pods' => { 'definitions' => {
        'db' => { 'manifest' => redis_pod },
        'app' => { 'manifest' => redis_pod, 'depends_on' => ['cache', 'db'] },
        'cache' => { 'manifest' => redis_pod, 'depends_on' => ['db'] },
        'tool' => { 'manifest' => redis_pod },
      } } })
      expect(bash_syntax_ok?(drain)).to be(true)
      expect(drain).to include('for name in tool app cache db; do', 'echo 0 >&3')
    end

    it 'rejects dependency cycles' do
      expect {
        render('pods', 'bin/drain', { 'pods' => { 'definitions' => {
          'a' => { 'manifest' => redis_pod, 'depends_on' => ['b'] },
          'b' => { 'manifest' => redis_pod, 'depends_on' => ['a'] },
        } } })
      }.to raise_error(/depends_on cycle a -> b -> a/)
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
    %w[bin/pre-start bin/post-start bin/drain bin/pod-ctl bin/pod-supervisor bin/pods-env.sh].each do |template|
      expect(bash_syntax_ok?(render('pods', template, props))).to be(true)
    end
  end
end
