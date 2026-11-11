# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 YunxiQWQ
require 'json'
require 'ipaddr'
require 'tempfile'

module CampusDualwan
  class Error < StandardError; end

  def self.json(path, private_file: false)
    secure_file!(path) if private_file
    result = JSON.parse(File.read(path))
    raise Error, 'Expected a JSON object' unless result.is_a?(Hash)
    result
  rescue JSON::ParserError
    raise Error, 'Invalid JSON; contents suppressed'
  end

  def self.secure_file!(path)
    info = File.lstat(path)
    raise Error, 'Private input must be a regular, non-symlink file' unless info.file? && !info.symlink?
    raise Error, 'Private input must belong to the running user and have mode 0600 or stricter' unless info.uid == Process.uid && (info.mode & 0o077).zero?
  end

  def self.atomically_write(path, text)
    raise Error, 'Refusing symlink output' if File.symlink?(path)
    Tempfile.create(['.campus-dualwan-', '.tmp'], File.dirname(path)) do |file|
      file.chmod(0o600)
      file.write(text)
      file.flush
      file.fsync
      File.rename(file.path, path)
    end
  end

  def self.identifier(value)
    raise Error, 'Invalid interface or identifier' unless value.is_a?(String) && value.match?(/\A[a-zA-Z0-9_.:-]{1,32}\z/)
    value
  end

  def self.ipv4(value, cidr: false)
    raise Error, 'Expected an IPv4 address' unless value.is_a?(String)
    raise Error, 'Unexpected address prefix' if !cidr && value.include?('/')
    address = IPAddr.new(value)
    raise Error, 'Only IPv4 is implemented' unless address.ipv4?
    value
  rescue IPAddr::InvalidAddressError, IPAddr::InvalidPrefixError
    raise Error, 'Invalid IPv4 address or prefix'
  end

  def self.integer(value, range)
    raise Error, 'Invalid integer setting' unless value.is_a?(Integer) && range.cover?(value)
    value
  end
end
