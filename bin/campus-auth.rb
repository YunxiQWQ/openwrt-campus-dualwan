#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
require 'tmpdir'
require_relative '../lib/portal'
begin
  raise CampusDualwan::Error, 'Usage: campus-auth.rb CONFIG.json --check|--run' unless ARGV.size == 2 && %w[--check --run].include?(ARGV.last)
  raise CampusDualwan::Error, 'Run as root on OpenWrt' unless Process.uid.zero?
  File.umask(0o077)
  config = CampusDualwan.json(ARGV.first, private_file: true)
  raise CampusDualwan::Error, 'Set configured=true only after replacing example settings' unless config['configured'] == true
  portal = CampusDualwan::Portal.new(config)
  if ARGV.last == '--check'
    %w[username_file password_file].each { |key| CampusDualwan.secure_file!(config.fetch(key)) }
    puts 'Authentication configuration and file permissions checked; no network request made.'
    exit 0
  end
  enabled, _error, process = Open3.capture3('uci', '-q', 'get', 'openclash.config.enable')
  if process.success? && enabled.strip == '1'
    unless config['transparent_proxy_bypass_verified'] == true && config['direct_gid'].is_a?(Integer)
      raise CampusDualwan::Error, 'Active OpenClash requires an explicitly verified direct GID bypass before authentication'
    end
  end
  state_directory = config.fetch('state_directory', '/tmp/campus-dualwan-auth')
  FileUtils.mkdir_p(state_directory, mode: 0o700)
  state_info = File.lstat(state_directory)
  raise CampusDualwan::Error, 'State directory must be root-owned mode 0700 and not a symlink' unless state_info.directory? && !state_info.symlink? && state_info.uid.zero? && (state_info.mode & 0o077).zero?
  # Enable only after verifying this GID is excluded from transparent interception.
  gid = config['direct_gid']
  Process::GID.change_privilege(CampusDualwan.integer(gid, 1..65535)) if gid
  File.open(File.join(state_directory, 'lock'), File::RDWR | File::CREAT, 0o600) do |lock|
    exit 0 unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    Dir.mktmpdir('request-', state_directory) do |directory|
      # Keep retry state outside the per-request directory, but all responses private.
      retry_file = File.join(state_directory, 'retry_at')
      local_retry = File.join(directory, 'retry_at')
      FileUtils.cp(retry_file, local_retry) if File.exist?(retry_file)
      result = portal.authenticate(directory)
      if result == :online
        FileUtils.rm_f(retry_file)
      elsif File.exist?(local_retry)
        CampusDualwan.atomically_write(retry_file, File.read(local_retry))
      end
      puts "campus-auth: #{result}"
      exit([:online, :backoff].include?(result) ? 0 : 1)
    end
  end
rescue StandardError => error
  warn(error.is_a?(CampusDualwan::Error) ? error.message : 'Authentication operation failed; private details suppressed')
  exit 1
end
