describe 'podman job' do
  describe 'config/containers.conf' do
    it 'renders valid TOML with BOSH paths and monit-friendly engine settings' do
      conf = toml(render('podman', 'config/containers.conf', {}))
      expect(conf['engine']['cgroup_manager']).to eq('cgroupfs')
      expect(conf['engine']['events_logger']).to eq('file')
      expect(conf['engine']['runtimes']['crun']).to eq(['/var/vcap/packages/podman/bin/crun'])
      expect(conf['engine']['conmon_path']).to eq(['/var/vcap/packages/podman/lib/podman/conmon'])
      expect(conf['engine']['tmp_dir']).to eq('/var/vcap/sys/run/podman/libpod')
      expect(conf['containers']['log_driver']).to eq('k8s-file')
      expect(conf['containers']['log_size_max']).to eq(10_485_760)
      expect(conf['network']).not_to have_key('firewall_driver')
    end

    it 'uses the persistent disk when present, the ephemeral disk otherwise' do
      with_disk = toml(render('podman', 'config/containers.conf', {}, persistent_disk: 10_240))
      without_disk = toml(render('podman', 'config/containers.conf', {}, persistent_disk: 0))
      expect(with_disk['network']['network_config_dir']).to eq('/var/vcap/store/podman/networks')
      expect(without_disk['network']['network_config_dir']).to eq('/var/vcap/data/podman/networks')
    end

    it 'deep-merges raw_config: nested merge, replace and nil removal' do
      conf = toml(render('podman', 'config/containers.conf', {
        'podman' => {
          'network' => { 'firewall_driver' => 'none' },
          'raw_config' => { 'containers_conf' => {
            'containers' => { 'pids_limit' => 4096, 'seccomp_profile' => nil },
            'engine' => { 'runtimes' => { 'runc' => ['/opt/runc'] } },
            'network' => { 'default_subnet_pools' => [{ 'base' => '10.89.0.0/16', 'size' => 24 }] },
          } },
        },
      }))
      expect(conf['containers']['pids_limit']).to eq(4096)
      expect(conf['containers']).not_to have_key('seccomp_profile')
      expect(conf['containers']['log_driver']).to eq('k8s-file')
      expect(conf['engine']['runtimes']).to eq('crun' => ['/var/vcap/packages/podman/bin/crun'], 'runc' => ['/opt/runc'])
      expect(conf['network']['firewall_driver']).to eq('none')
      expect(conf['network']['default_subnet_pools']).to eq([{ 'base' => '10.89.0.0/16', 'size' => 24 }])
    end
  end

  describe 'config/storage.conf' do
    it 'renders valid TOML' do
      conf = toml(render('podman', 'config/storage.conf', {}, persistent_disk: 1))
      expect(conf['storage']).to include('driver' => 'overlay', 'graphroot' => '/var/vcap/store/podman/storage',
                                         'runroot' => '/var/vcap/sys/run/podman/storage')
    end
  end

  describe 'config/registries.conf' do
    it 'renders insecure registries and mirrors as [[registry]] tables' do
      conf = toml(render('podman', 'config/registries.conf', {
        'podman' => { 'registries' => {
          'insecure' => ['registry.local:5000'],
          'mirrors' => { 'docker.io' => ['mirror.example.com/hub', { 'location' => 'm.local:5000', 'insecure' => true }] },
        } },
      }))
      expect(conf['unqualified-search-registries']).to eq(['docker.io'])
      expect(conf['registry']).to contain_exactly(
        { 'prefix' => 'registry.local:5000', 'location' => 'registry.local:5000', 'insecure' => true },
        { 'prefix' => 'docker.io', 'location' => 'docker.io',
          'mirror' => [{ 'location' => 'mirror.example.com/hub' }, { 'location' => 'm.local:5000', 'insecure' => true }] },
      )
    end
  end

  describe 'config/auth.json' do
    it 'renders base64 credentials' do
      auth = JSON.parse(render('podman', 'config/auth.json', {
        'podman' => { 'registries' => { 'auth' => { 'registry.example.com' => { 'username' => 'u', 'password' => 'p:w' } } } },
      }))
      expect(auth['auths']['registry.example.com']['auth']).to eq(['u:p:w'].pack('m0'))
    end

    it 'requires username and password' do
      expect {
        render('podman', 'config/auth.json', { 'podman' => { 'registries' => { 'auth' => { 'r' => { 'username' => 'u' } } } } })
      }.to raise_error(/username and password are required/)
    end
  end

  it 'keeps the shared ERB helpers identical in all TOML templates' do
    helpers = %w[containers.conf storage.conf registries.conf].map do |name|
      File.read(File.join(RELEASE_DIR, "jobs/podman/templates/config/#{name}.erb"))[/# ---- shared helpers.*?# ---- end of shared helpers ----/m]
    end
    expect(helpers.compact.size).to eq(3)
    expect(helpers.uniq.size).to eq(1)
  end

  it 'renders a syntactically valid pre-start' do
    expect(bash_syntax_ok?(render('podman', 'bin/pre-start', {}))).to be(true)
  end
end
