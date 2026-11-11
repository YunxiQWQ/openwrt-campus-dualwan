# SPDX-License-Identifier: GPL-3.0-only
# Offline tests: all accounts, portal origins and nodes here are fictional.
require 'tmpdir'
require 'stringio'
require_relative '../lib/renderer'
require_relative '../lib/network_fragment'
require_relative '../lib/portal'

def assert(value, message = 'assertion failed')
  raise message unless value
end

def rejected
  begin
    yield
  rescue CampusDualwan::Error
    return
  end
  raise 'expected a controlled rejection'
end

class FakeTransport
  attr_reader :requests, :renewed
  def initialize(login_result: 'success', final_online: true, encryption: false)
    @login_result, @final_online, @encryption = login_result, final_online, encryption
    @requests, @logged_in, @renewed = [], false, false
  end
  def status(_interface)
    {device: 'wlan1', ip: @logged_in ? '192.0.2.30' : '192.0.2.10'}
  end
  def request(device, url, _directory, body: nil)
    @requests << {device: device, url: url, body: body}
    if url.end_with?('pageInfo')
      {code: 200, headers: '', body: JSON.dump('passwordEncrypt' => @encryption)}
    elsif url.end_with?('method=login')
      @logged_in = @login_result == 'success'
      {code: 200, headers: '', body: JSON.dump('result' => @login_result)}
    elsif @logged_in && @final_online
      {code: 200, headers: '', body: 'OK'}
    else
      {code: 302, headers: 'Location: http://198.51.100.1/eportal/index.jsp?wlanuserip=192.0.2.10&session=TEST_ONLY', body: ''}
    end
  end
  def renew(_interface)
    @renewed = true
  end
  def wait(_seconds); end
end

root = File.expand_path('..', __dir__)
settings = JSON.parse(File.read(File.join(root, 'examples/render.example.json')))
source = File.read(File.join(root, 'examples/provider.example.yaml'))
tests = {}
tests['alias expansion preserves explicit TLS identity; DIRECT is not globally marked'] = lambda do
  result = YAML.safe_load(CampusDualwan::Renderer.render(source, settings))
  proxy = result['proxies'].first
  assert(proxy['server'] == 'endpoint.example.org')
  assert(proxy['sni'] == 'node.example.org')
  assert(proxy['interface-name'] == 'wlan0' && proxy['routing-mark'] == 6666)
  assert(proxy['skip-cert-verify'] == false)
  assert(!result.key?('routing-mark') && !result.key?('interface-name'))
end
tests['rendering twice is stable'] = lambda do
  once = CampusDualwan::Renderer.render(source, settings)
  twice = CampusDualwan::Renderer.render(once, settings)
  assert(YAML.safe_load(once) == YAML.safe_load(twice))
end
tests['alias cycles and dynamic providers are rejected'] = lambda do
  object = YAML.safe_load(source)
  object['hosts']['endpoint.example.org'] = 'node.example.org'
  rejected { CampusDualwan::Renderer.render(YAML.dump(object), settings) }
  object = YAML.safe_load(source)
  object['proxy-providers'] = {'remote' => {'type' => 'http'}}
  rejected { CampusDualwan::Renderer.render(YAML.dump(object), settings) }
end
tests['aliased TLS node without SNI is not guessed'] = lambda do
  object = YAML.safe_load(source)
  object['proxies'].first.delete('sni')
  rejected { CampusDualwan::Renderer.render(YAML.dump(object), settings) }
end
tests['shell/UCI metacharacters and reserved route tables are rejected'] = lambda do
  config = JSON.parse(File.read(File.join(root, 'examples/network.example.json')))
  config['mobile_interface'] = "mobile'; reboot"
  rejected { CampusDualwan::NetworkFragment.render(config) }
  config['mobile_interface'] = 'mobile'
  config['table'] = 254
  rejected { CampusDualwan::NetworkFragment.render(config) }
end
tests['network guard belongs to loopback; mobile and LAN routes are separate'] = lambda do
  config = JSON.parse(File.read(File.join(root, 'examples/network.example.json')))
  fragment = CampusDualwan::NetworkFragment.render(config)
  guard = fragment.split("\n\n").find { |section| section.include?("'cdw_guard'") }
  assert(guard.include?("interface 'loopback'") && guard.include?("type 'unreachable'"))
  assert(fragment.include?("target '192.168.50.0/24'") && fragment.include?("mark '0x1a0a/0xffffffff'"))
end
tests['portal query rejects foreign origins, userinfo and wrong paths'] = lambda do
  config = JSON.parse(File.read(File.join(root, 'examples/auth.example.json')))
  portal = CampusDualwan::Portal.new(config)
  rejected { portal.query('http://203.0.113.2/eportal/index.jsp?wlanuserip=192.0.2.10') }
  rejected { portal.query('http://other@198.51.100.1/eportal/index.jsp?wlanuserip=192.0.2.10') }
  rejected { portal.query('http://198.51.100.1/other?wlanuserip=192.0.2.10') }
  assert(portal.query('Location: http://198.51.100.1/eportal/index.jsp?wlanuserip=192.0.2.10&amp;session=TEST_ONLY').include?('&session='))
end
tests['double encoding round-trips reserved characters'] = lambda do
  username = 'TEST_ONLY&a+b'
  form = CampusDualwan::Portal.login_form(username, 'TEST_ONLY%&=', 'wlanuserip=192.0.2.10&session=TEST_ONLY')
  fields = URI.decode_www_form(form).to_h
  assert(URI.decode_www_form_component(fields['userId']) == username)
  assert(URI.decode_www_form_component(fields['password']) == 'TEST_ONLY%&=')
end

Dir.mktmpdir('campus-dualwan-tests-') do |temporary|
  username = File.join(temporary, 'username')
  password = File.join(temporary, 'password')
  File.write(username, 'TEST_ONLY_ACCOUNT', mode: 'w', perm: 0o600)
  File.write(password, 'TEST_ONLY_PASSWORD', mode: 'w', perm: 0o600)
  config = JSON.parse(File.read(File.join(root, 'examples/auth.example.json')))
  config.merge!('username_file' => username, 'password_file' => password,
                'renew_before_cidrs' => ['192.0.2.0/24'],
                'connectivity_checks' => [{'url' => 'http://check.example.org/', 'status' => 200, 'body' => 'OK'},
                                          {'url' => 'https://check.example.org/', 'status' => 200, 'body' => 'OK'}])
  tests['accepted login is followed by renew and real connectivity checks'] = lambda do
    Dir.mktmpdir('request-', temporary) do |directory|
      transport = FakeTransport.new
      assert(CampusDualwan::Portal.new(config, transport: transport).authenticate(directory) == :online)
      assert(transport.renewed)
      assert(transport.requests.all? { |request| request[:device] == 'wlan1' })
    end
  end
  tests['portal success alone is not Internet success'] = lambda do
    Dir.mktmpdir('request-', temporary) do |directory|
      transport = FakeTransport.new(final_online: false)
      result = CampusDualwan::Portal.new(config, transport: transport).authenticate(directory, now: 1000)
      assert(result == :accepted_but_unverified)
      assert(File.read(File.join(directory, 'retry_at')) == '1060')
    end
  end
  tests['rejection backs off for fifteen minutes without another login'] = lambda do
    Dir.mktmpdir('request-', temporary) do |directory|
      transport = FakeTransport.new(login_result: 'fail')
      portal = CampusDualwan::Portal.new(config, transport: transport)
      assert(portal.authenticate(directory, now: 1000) == :rejected)
      assert(portal.authenticate(directory, now: 1001) == :backoff)
      assert(transport.requests.count { |r| r[:url].end_with?('method=login') } == 1)
    end
  end
  tests['encrypted portal flow never submits credentials'] = lambda do
    Dir.mktmpdir('request-', temporary) do |directory|
      transport = FakeTransport.new(encryption: true)
      rejected { CampusDualwan::Portal.new(config, transport: transport).authenticate(directory) }
      assert(transport.requests.none? { |r| r[:url].end_with?('method=login') })
    end
  end
  tests['world-readable private inputs and symlink outputs are rejected'] = lambda do
    File.chmod(0o644, username)
    rejected { CampusDualwan.secure_file!(username) }
    File.chmod(0o600, username)
    link = File.join(temporary, 'symlink')
    File.symlink(password, link)
    rejected { CampusDualwan.atomically_write(link, 'changed') }
    assert(File.read(password) == 'TEST_ONLY_PASSWORD')
  end
  tests['atomic output permissions are private'] = lambda do
    output = File.join(temporary, 'rendered')
    CampusDualwan.atomically_write(output, 'TEST_ONLY')
    assert((File.stat(output).mode & 0o777) == 0o600)
  end
  failed = 0
  tests.each do |name, action|
    begin
      action.call
      puts "PASS #{name}"
    rescue StandardError => error
      failed += 1
      warn "FAIL #{name}: #{error.class} #{error.message}"
    end
  end
  puts "#{tests.size} tests, #{failed} failures"
  exit(failed.zero? ? 0 : 1)
end
