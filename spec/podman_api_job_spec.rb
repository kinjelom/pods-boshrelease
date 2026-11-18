describe 'podman-api job' do
  it 'renders a root-only socket by default' do
    ctl = render('podman-api', 'bin/ctl', {})
    expect(bash_syntax_ok?(ctl)).to be(true)
    expect(ctl).to include('SOCKET_DIR=/var/vcap/sys/run/podman-api', "GROUP_GID=\n",
                           'podman system service --time=0 "unix://$SOCKET"', 'secure_socket "$pid"',
                           'chmod 0700 "$SOCKET_DIR"', 'chmod 0600 "$SOCKET"')
  end

  it 'opens the socket to one group' do
    ctl = render('podman-api', 'bin/ctl', { 'podman_api' => { 'group_gid' => 2375, 'socket_dir' => '/var/vcap/sys/run/ci api' } })
    expect(bash_syntax_ok?(ctl)).to be(true)
    expect(ctl).to include('GROUP_GID=2375', 'SOCKET_DIR=/var/vcap/sys/run/ci\ api',
                           'chown "root:$GROUP_GID" "$SOCKET_DIR"', 'chmod 0750 "$SOCKET_DIR"', 'chmod 0660 "$SOCKET"')
  end

  it 'rejects a non-numeric group' do
    expect { render('podman-api', 'bin/ctl', { 'podman_api' => { 'group_gid' => 'docker' } }) }
      .to raise_error(/group_gid must be a numeric GID/)
  end

  it 'stops the service when its socket does not appear' do
    ctl = render('podman-api', 'bin/ctl', {})
    body = ctl[/function secure_socket\(\) \{.*?^\}/m]
    expect(body).to include('kill -KILL "$1"', 'rm -f "$PID_FILE"', 'exit 1')
  end

  it 'rejects an unknown action before touching the system' do
    ctl = render('podman-api', 'bin/ctl', {})
    [[], ['restart']].each do |argv|
      _out, err, status = Open3.capture3('bash', '-c', ctl, 'ctl', *argv)
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Usage: ctl {start|stop}')
    end
  end

  it 'is one monit process with a fixed pid file' do
    monit = render('podman-api', 'monit', {})
    expect(monit).to include('check process podman-api', 'pidfile /var/vcap/sys/run/podman-api/podman-api.pid',
                             'bin/ctl start"', 'bin/ctl stop"')
  end
end
