#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Parameterized from the deployed mobile-up recovery hook; raw service logs discarded.
require 'uri'
require 'open3'
require 'fileutils'
require_relative '../lib/common'
begin
  raise CampusDualwan::Error, 'Usage: recover-mobile.rb CONFIG.json' unless ARGV.size == 1
  raise CampusDualwan::Error, 'Run as root on OpenWrt' unless Process.uid.zero?
  File.umask(0o077)
  config = CampusDualwan.json(ARGV.first, private_file: true)
  raise CampusDualwan::Error, 'Configure recovery explicitly before enabling the hook' unless config['configured'] == true
  mobile = CampusDualwan.identifier(config.fetch('mobile_interface'))
  exit 0 unless ENV['ACTION'] == 'ifup' && ENV['INTERFACE'] == mobile
  curl_config = config.fetch('curl_config')
  CampusDualwan.secure_file!(curl_config)
  url = URI.parse(config.fetch('health_url'))
  raise CampusDualwan::Error, 'Health URL must be HTTPS without userinfo or query' unless url.scheme == 'https' && url.host && !url.userinfo && !url.query && !url.fragment
  port = CampusDualwan.integer(config.fetch('socks_port'), 1..65535)
  expected = CampusDualwan.integer(config.fetch('health_status'), 200..299)
  directory = '/tmp/campus-dualwan-recovery'
  FileUtils.mkdir_p(directory, mode: 0o700)
  info = File.lstat(directory)
  raise CampusDualwan::Error, 'Unsafe recovery state directory' unless info.directory? && !info.symlink? && info.uid.zero? && (info.mode & 0o077).zero?
  File.open(File.join(directory, 'lock'), File::RDWR | File::CREAT, 0o600) do |lock|
    exit 0 unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    sleep 2
    # Do not start a disabled service simply because an interface came up.
    enabled, _err, status = Open3.capture3('uci', '-q', 'get', 'openclash.config.enable')
    exit 0 unless status.success? && enabled.strip == '1'
    exit 0 unless system('pidof', 'clash', out: File::NULL, err: File::NULL)
    ok = system('timeout', '90', '/etc/init.d/openclash', 'restart', out: File::NULL, err: File::NULL)
    healthy = false
    if ok
      3.times do
        code, _err, result = Open3.capture3('curl', '--config', curl_config, '--noproxy', '', '--socks5-hostname', "127.0.0.1:#{port}",
                                         '--connect-timeout', '3', '--max-time', '8', '--silent', '--output', '/dev/null',
                                         '--write-out', '%{http_code}', '--proto', '=https', url.to_s)
        healthy = result.success? && code.to_i == expected
        break if healthy
        sleep 2
      end
    end
    puts "mobile-recovery: #{healthy ? 'healthy' : 'unverified'}"
    exit(healthy ? 0 : 1)
  end
rescue StandardError => error
  warn(error.is_a?(CampusDualwan::Error) ? error.message : 'Recovery failed; private details suppressed')
  exit 1
end
