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
      # renders the definition and returns [EGRESS_RULES, EGRESS_DNS, EGRESS_LOG] as sourced by bash
      def egress(definition, defaults = {})
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'defaults' => defaults, 'definitions' => {
          'app' => { 'manifest' => redis_pod }.merge(definition),
        } } })
        env = written_definitions(pre_start)['app']['env']
        out, status = Open3.capture2('bash', '-c', env + "\nprintf '%s\\0%s\\0%s' \"$EGRESS_RULES\" \"$EGRESS_DNS\" \"$EGRESS_LOG\"")
        raise 'invalid definition.env' unless status.success?
        out.split("\0", 3)
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
        rules, dns, log = egress('egress' => { 'allow' => [
          { 'to' => '10.0.5.20', 'port' => 5432 },
          { 'to' => '10.0.6.7/24', 'protocol' => 'UDP', 'ports' => [514, '6000-6010', 514] },
          { 'to' => '2001:db8::/32', 'protocol' => 'all' },
          { 'to' => '10.0.7.1', 'protocol' => 'icmp' },
          { 'to' => '0.0.0.0/0', 'port' => 443 },
        ] })
        expect(dns).to eq('false')
        expect(log).to eq('blocked')
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
        rules, dns, = egress('egress' => { 'allow' => [], 'dns' => true })
        expect(dns).to eq('true')
        expect(rules).to include('set dns4 { type ipv4_addr; }', 'ip daddr @dns4 meta l4proto { tcp, udp } th dport 53 accept')
        expect(rules).not_to match(/daddr \d/)
        script = rules + "add element inet pods_egress dns4 { 10.89.0.1 }\nadd element inet pods_egress dns6 { fd00::1 }\n"
        loaded = nft_load(script)
        skip 'nft in an unprivileged user namespace is not available' if loaded.nil?
        expect(loaded).to be(true)
      end

      it 'is off without the key' do
        expect(egress({})).to eq(['', 'false', 'none'])
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => { 'app' => { 'manifest' => redis_pod } } } })
        expect(pre_start).not_to include('nsenter')
      end

      it 'checks for nft and nsenter on the stemcell' do
        pre_start = render('pods', 'bin/pre-start', { 'pods' => { 'definitions' => {
          'app' => { 'manifest' => redis_pod, 'egress' => { 'allow' => [] } },
        } } })
        expect(bash_syntax_ok?(pre_start)).to be(true)
        expect(pre_start).to include('for tool in nft nsenter; do', "definition 'app': egress restricted to 0 allow rule(s), connection log: blocked")
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
        expect { egress('egress' => { 'allow' => [], 'logs' => true }) }.to raise_error(/egress: unknown key\(s\) logs/)
        expect { egress('egress' => { 'allow' => [], 'log' => true }) }.to raise_error(/egress.log: "true" is not none, blocked, all/)
        expect { egress({ 'egress' => { 'allow' => [] } }, { 'egress_log' => 'some' }) }.to raise_error(/egress.log: "some" is not/)
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

      describe 'connection log' do
        let(:allow) { [{ 'to' => '10.0.5.20', 'port' => 5432 }, { 'to' => '10.0.7.1', 'protocol' => 'icmp' }] }

        # bin/egress-log.awk run by every awk of the host (the stemcell's awk is mawk)
        def egress_log(listing)
          awks = %w[mawk gawk].select { |awk| system("command -v #{awk} > /dev/null") }
          awks = ['awk'] if awks.empty?
          awks.map do |awk|
            Dir.mktmpdir do |dir|
              File.write(File.join(dir, 'egress-log.awk'), render('pods', 'bin/egress-log.awk', {}))
              _out, err, status = Open3.capture3(awk, '-v', 'time=T', '-v', 'prefix=definition=app pod=app', '-v', 'logfile=egress.log',
                                                 '-v', 'deletefile=delete.nft', '-f', 'egress-log.awk', stdin_data: listing, chdir: dir)
              raise "#{awk} failed: #{err}" unless status.success?
              read = ->(file) { File.exist?(File.join(dir, file)) ? File.read(File.join(dir, file)).lines.map(&:chomp).sort : [] }
              [read.call('egress.log'), read.call('delete.nft')]
            end
          end
        end

        it 'records blocked packets by default, every new connection with log: all, nothing with log: none' do
          blocked, = egress('egress' => { 'allow' => allow })
          expect(blocked).to include(
            'set blocked4 { type ipv4_addr . inet_proto . inet_service; size 4096; flags dynamic; }',
            'set blocked6_noport { type ipv6_addr . inet_proto; size 4096; flags dynamic; }',
            'meta nfproto ipv4 meta l4proto { tcp, udp } add @blocked4 { ip daddr . meta l4proto . th dport counter }',
            'meta nfproto ipv6 meta l4proto != { tcp, udp } add @blocked6_noport { ip6 daddr . meta l4proto counter }',
            'ip daddr 10.0.5.20 tcp dport { 5432 } accept'
          )
          expect(blocked.index('add @blocked4')).to be < blocked.index('reject with tcp reset')
          expect(blocked).not_to include('allowed')

          all, _dns, log = egress('egress' => { 'allow' => allow, 'dns' => true, 'log' => 'all' })
          expect(log).to eq('all')
          expect(all).to include(
            'ip daddr 10.0.5.20 tcp dport { 5432 } goto allowed', 'ip daddr 10.0.7.1 meta l4proto icmp goto allowed',
            'ip daddr @dns4 meta l4proto { tcp, udp } th dport 53 goto allowed', 'add @blocked4',
            "chain allowed {\n    ct mark 0x1 accept\n    ct mark set 0x1\n",
            'add @allowed6_noport { ip6 daddr . meta l4proto counter }'
          )

          none, _dns, log = egress({ 'egress' => { 'allow' => allow } }, { 'egress_log' => 'none' })
          expect(log).to eq('none')
          expect(none).to include('ip daddr 10.0.5.20 tcp dport { 5432 } accept')
          expect(none).not_to match(/ set |add @|allowed/)

          [blocked, all, none].each do |rules|
            skip 'nft in an unprivileged user namespace is not available' if nft_load(rules).nil?
          end
        end

        it 'logs the listed elements (nft 1.0 and 1.1 output), deletes them and warns about a full set' do
          listing = <<~NFT
            table inet pods_egress {
                set dns4 {
                    type ipv4_addr
                    elements = { 10.89.0.1 }
                }

                set allowed4 {
                    type ipv4_addr . inet_proto . inet_service
                    size 4096
                    flags dynamic
                    elements = { 10.0.6.7 . 17 . 514 counter packets 1 bytes 30,
                                 10.0.5.20 . 6 . 5432 counter packets 2 bytes 120 }
                }

                set blocked4 {
                    type ipv4_addr . inet_proto . inet_service
                    size 4096
                    flags dynamic
                }

                set blocked4_noport {
                    type ipv4_addr . inet_proto
                    size 2\t# count 2
                    flags dynamic
                    elements = { 10.0.7.2 . 1 counter packets 1 bytes 84, 10.0.7.3 . 47 counter packets 9 bytes 900 }
                }

                set blocked6 {
                    type ipv6_addr . inet_proto . inet_service
                    size 4096\t# count 1
                    flags dynamic
                    elements = { fd00::99 . 17 . 123 counter packets 1 bytes 50 }
                }

                chain output {
                    type filter hook output priority filter; policy drop;
                    meta l4proto { tcp, udp } add @blocked4 { ip daddr . meta l4proto . th dport counter }
                }
            }
          NFT
          egress_log(listing).each do |log, delete|
            expect(log).to eq([
              'T definition=app pod=app verdict=allowed proto=tcp dst=10.0.5.20 dport=5432 count=2',
              'T definition=app pod=app verdict=allowed proto=udp dst=10.0.6.7 dport=514 count=1',
              'T definition=app pod=app verdict=blocked proto=47 dst=10.0.7.3 count=9',
              'T definition=app pod=app verdict=blocked proto=icmp dst=10.0.7.2 count=1',
              'T definition=app pod=app verdict=blocked proto=udp dst=fd00::99 dport=123 count=1',
              'T definition=app pod=app verdict=blocked warning="log set blocked4_noport full (2 destinations within one poll), further destinations not logged"',
            ])
            expect(delete).to eq([
              'delete element inet pods_egress allowed4 { 10.0.6.7 . 17 . 514, 10.0.5.20 . 6 . 5432 }',
              'delete element inet pods_egress blocked4_noport { 10.0.7.2 . 1, 10.0.7.3 . 47 }',
              'delete element inet pods_egress blocked6 { fd00::99 . 17 . 123 }',
            ])
          end
          expect(egress_log("table inet pods_egress {\n}\n")).to all(eq([[], []]))
        end

        # real traffic in a throw-away network namespace: new connections counted once, blocked packets each
        # (lo carries the TCP resets back to the application)
        it 'records real connections that the supervisor moves into egress.log' do
          rules, = egress('egress' => { 'allow' => [
            { 'to' => '10.0.5.20', 'port' => 5432 }, { 'to' => '10.0.6.0/24', 'protocol' => 'udp', 'port' => 514 },
          ], 'log' => 'all' })
          skip 'nft in an unprivileged user namespace is not available' if nft_load(rules).nil?
          script = <<~'BASH'
            set -e
            ip link add d0 type dummy
            ip addr add 10.0.0.2/8 dev d0
            ip -6 addr add fd00::2/64 dev d0 nodad
            ip link set d0 up
            ip link set lo up
            nft -f rules.nft
            for i in 1 2 3; do (echo > /dev/tcp/10.0.9.5/443) 2> /dev/null || true; done
            timeout 0.2 bash -c 'echo > /dev/tcp/10.0.5.20/5432' || true
            exec 7> /dev/udp/10.0.6.7/514
            for i in 1 2 3 4 5; do echo x >&7; done
            exec 7>&-
            (echo x > /dev/udp/fd00::99/123) 2> /dev/null || true
          BASH
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, 'rules.nft'), rules)
            # the listing goes through the awk script between two nft calls, like in the supervisor
            out, status = Open3.capture2e('unshare', '-rn', 'bash', '-c', script + 'nft -n list table inet pods_egress', chdir: dir)
            skip "no network namespace with a dummy interface: #{out}" unless status.success?
            log, delete = egress_log(out).first
            expect(log.reject { |line| line.include?('dst=ff02::') }).to eq([
              'T definition=app pod=app verdict=allowed proto=tcp dst=10.0.5.20 dport=5432 count=1',
              'T definition=app pod=app verdict=allowed proto=udp dst=10.0.6.7 dport=514 count=1',
              'T definition=app pod=app verdict=blocked proto=tcp dst=10.0.9.5 dport=443 count=3',
              'T definition=app pod=app verdict=blocked proto=udp dst=fd00::99 dport=123 count=1',
            ])
            File.write(File.join(dir, 'delete.nft'), delete.join("\n") + "\n")
            out, status = Open3.capture2e('unshare', '-rn', 'bash', '-c',
                                          script + "nft -f delete.nft\nnft -n list table inet pods_egress | grep -c 'elements = ' || true", chdir: dir)
            expect(status.success?).to be(true), out
            expect(out.strip).to eq('0')
          end
        end
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

  describe 'bin/pods' do
    it 'is linked into /usr/local/bin with an optional bash completion' do
      props = ->(profile) { { 'pods' => { 'shell_profile' => profile, 'definitions' => { 'redis' => { 'manifest' => redis_pod } } } } }
      pre_start = render('pods', 'bin/pre-start', props.call(true))
      expect(pre_start).to include('ln -sfn "$PODS_JOB_DIR/bin/pods" /usr/local/bin/pods',
                                   'eval "$(/var/vcap/jobs/pods/bin/pods completion bash)"')
      expect(render('pods', 'bin/pre-start', props.call(false))).to include('rm -f /etc/profile.d/pods-bosh.sh')
    end

    it 'prints its usage and the bash completion without the job environment' do
      Dir.mktmpdir do |dir|
        pods = File.join(dir, 'pods')
        File.write(pods, render('pods', 'bin/pods', {}))
        out, status = Open3.capture2('bash', pods, 'help')
        expect(status.success?).to be(true)
        expect(out).to include('Usage: pods', 'logs     <definition> [-c <container>]')
        completion, status = Open3.capture2('bash', pods, 'completion', 'bash')
        expect(status.success?).to be(true)
        expect(bash_syntax_ok?(completion)).to be(true)
        expect(completion).to include('complete -F _pods_complete pods')
      end
    end
  end

  it 'renders syntactically valid scripts' do
    props = { 'pods' => { 'definitions' => { 'redis' => { 'manifest' => redis_pod } } } }
    %w[bin/pre-start bin/post-start bin/drain bin/pod-ctl bin/pod-supervisor bin/pods-env.sh bin/pods].each do |template|
      expect(bash_syntax_ok?(render('pods', template, props))).to be(true)
    end
  end
end
