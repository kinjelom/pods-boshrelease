describe 'podman-exporter job' do
  # the ARGS bash array as the shell sees it, joined with spaces
  def args(ctl)
    out, status = Open3.capture2('bash', '-c', ctl[/^ARGS=\(.*\)$/] + "\nprintf '%s\\n' \"${ARGS[@]}\"")
    raise 'cannot evaluate ARGS' unless status.success?
    out.split("\n").join(' ')
  end

  it 'renders the default command line' do
    ctl = render('podman-exporter', 'bin/ctl', {})
    expect(bash_syntax_ok?(ctl)).to be(true)
    expect(args(ctl)).to eq('--web.listen-address=:9882 --web.telemetry-path=/metrics --web.max-requests=4 ' \
                            '--collector.cache-duration=1h --collector.container-stats-timeout=5s ' \
                            '--collector.pod --collector.volume --collector.image --collector.network --collector.system ' \
                            '--collector.enhance-metrics')
  end

  it 'renders labels, port and extra args' do
    ctl = render('podman-exporter', 'bin/ctl', { 'podman_exporter' => {
      'port' => 9100, 'bind_address' => '127.0.0.1', 'collectors' => ['pod'],
      'whitelisted_labels' => ['app', 'app.kubernetes.io/name'], 'enhance_metrics' => false,
      'extra_args' => ['--web.config.file=/x y'],
    } })
    expect(args(ctl)).to include('--web.listen-address=127.0.0.1:9100', '--collector.pod',
                                 '--collector.whitelisted-labels=app,app.kubernetes.io/name', '--web.config.file=/x y')
    expect(args(ctl)).not_to include('--collector.volume', '--collector.enhance-metrics')
  end

  it 'prefers store_labels over whitelisted labels' do
    ctl = render('podman-exporter', 'bin/ctl', { 'podman_exporter' => { 'store_labels' => true, 'whitelisted_labels' => ['app'] } })
    expect(args(ctl)).to include('--collector.store-labels')
    expect(args(ctl)).not_to include('whitelisted')
  end

  it 'rejects unknown collectors' do
    expect {
      render('podman-exporter', 'bin/ctl', { 'podman_exporter' => { 'collectors' => ['containers'] } })
    }.to raise_error(/unknown \["containers"\]/)
  end
end
