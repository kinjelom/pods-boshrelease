require 'bosh/template/test'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'open3'
require 'yaml'

RELEASE_DIR = File.expand_path('..', __dir__)

# bosh-template's InstanceSpec has no persistent_disk
class InstanceSpecWithDisk < Bosh::Template::Test::InstanceSpec
  def initialize(persistent_disk)
    super()
    @persistent_disk = persistent_disk
  end

  def to_h
    super.merge('persistent_disk' => @persistent_disk)
  end
end

module RenderHelpers
  def release
    @release ||= Bosh::Template::Test::ReleaseDir.new(RELEASE_DIR)
  end

  # Renders a job template (by its rendered path) or the job's `monit` file
  def render(job_name, template_path, properties, persistent_disk: 0)
    template =
      if template_path == 'monit'
        job_dir = File.join(RELEASE_DIR, 'jobs', job_name)
        Bosh::Template::Test::Template.new(YAML.load_file(File.join(job_dir, 'spec')), File.join(job_dir, 'monit'))
      else
        release.job(job_name).template(template_path)
      end
    template.render(properties, spec: InstanceSpecWithDisk.new(persistent_disk))
  end

  # Validates TOML with a real parser (spec/tools/tomljson, Go) and returns it as a hash
  def toml(content)
    out, err, status = Open3.capture3(TOMLJSON_BIN, stdin_data: content)
    raise "invalid TOML: #{err}\n#{content}" unless status.success?
    JSON.parse(out)
  end

  def bash_syntax_ok?(content)
    _out, err, status = Open3.capture3('bash', '-n', stdin_data: content)
    raise "bash syntax error: #{err}" unless status.success?
    true
  end
end

TOMLJSON_BIN = File.join(Dir.tmpdir, "pods-boshrelease-tomljson-#{Process.pid}")

RSpec.configure do |config|
  config.include RenderHelpers

  config.before(:suite) do
    _out, err, status = Open3.capture3('go', 'build', '-o', TOMLJSON_BIN, '.', chdir: File.join(__dir__, 'tools/tomljson'))
    raise "cannot build spec/tools/tomljson: #{err}" unless status.success?
  end
  config.after(:suite) { FileUtils.rm_f(TOMLJSON_BIN) }
end
