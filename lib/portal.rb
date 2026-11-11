# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 YunxiQWQ
# ePortal form encoding is adapted from nekomiya-hinata/RuijiePortalLoginScript
# (Openwrt & LEDE/ruijie_general.sh), GPL-3.0. See THIRD_PARTY.md.
require 'uri'
require 'open3'
require 'fileutils'
require_relative 'common'

module CampusDualwan
  class CurlTransport
    def status(interface)
      text, _error, process = Open3.capture3('ubus', 'call', "network.interface.#{CampusDualwan.identifier(interface)}", 'status')
      raise Error, 'Cannot read campus interface' unless process.success?
      status = JSON.parse(text)
      raise Error, 'Campus interface is down' unless status['up'] == true
      {device: status.fetch('l3_device'), ip: status.fetch('ipv4-address').first.fetch('address')}
    rescue JSON::ParserError, KeyError, NoMethodError
      raise Error, 'Invalid campus interface status'
    end

    def request(device, url, directory, body: nil)
      # Bodies, cookies and session query strings never go to stdout or argv.
      header = File.join(directory, 'headers')
      output = File.join(directory, 'body')
      argv = ['curl', '-4', '--noproxy', '*', '--interface', device,
              '--connect-timeout', '4', '--max-time', '12', '--max-filesize', '1048576',
              '--silent', '--dump-header', header, '--output', output, '--write-out', '%{http_code}',
              '--proto', '=http,https']
      if body
        argv += ['--header', 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8', '--data-binary', '@-']
      end
      code, _error, process = Open3.capture3(*argv, url, stdin_data: body.to_s)
      raise Error, "Bound HTTP request failed (curl exit #{process.exitstatus}); response suppressed" unless process.success?
      {code: code.to_i, headers: File.read(header), body: File.read(output)}
    end

    def renew(interface)
      _out, _error, status = Open3.capture3('ifup', CampusDualwan.identifier(interface))
      raise Error, 'Campus DHCP renew failed' unless status.success?
    end

    def wait(seconds)
      sleep seconds
    end
  end

  class Portal
    def initialize(config, transport: CurlTransport.new)
      @config, @transport = config, transport
      @origin = self.class.url(config.fetch('portal_origin'))
      raise Error, 'portal_origin must contain only scheme, host and optional port' unless ['', '/'].include?(@origin.path) && !@origin.query && !@origin.fragment
      @origin.path = ''
      CampusDualwan.identifier(config.fetch('campus_interface'))
      CampusDualwan.identifier(config.fetch('campus_device'))
      @checks = config.fetch('connectivity_checks')
      raise Error, 'Use at least two connectivity checks' unless @checks.is_a?(Array) && @checks.size >= 2
      @checks.each do |check|
        self.class.url(check.fetch('url'))
        CampusDualwan.integer(check.fetch('status'), 200..299)
      end
      @renew_cidrs = config.fetch('renew_before_cidrs', []).map { |value| IPAddr.new(CampusDualwan.ipv4(value, cidr: true)) }
    rescue KeyError
      raise Error, 'Missing authentication setting'
    end

    def self.url(value)
      uri = URI.parse(value)
      raise Error, 'Expected an HTTP(S) URL without userinfo' unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.fragment
      uri
    rescue URI::InvalidURIError, TypeError
      raise Error, 'Invalid URL setting'
    end

    def query(text)
      text = text.gsub('&amp;', '&').gsub('\\/', '/')
      text.scan(%r{https?://[^\s<>"']+}).each do |candidate|
        uri = URI.parse(candidate.sub(/\\\z/, '')) rescue next
        next unless [uri.scheme, uri.host, uri.port] == [@origin.scheme, @origin.host, @origin.port]
        next unless !uri.userinfo && !uri.fragment && uri.path == '/eportal/index.jsp' && uri.query
        next if uri.query.match?(/[\r\n]/)
        values = URI.decode_www_form(uri.query) rescue next
        next unless values.any? { |key, value| key == 'wlanuserip' && !value.empty? }
        return uri.query
      end
      raise Error, 'No redirect from the configured trusted portal; no credentials submitted'
    end

    def self.login_form(username, password, raw_query, service = '')
      encode_twice = ->(value) { URI.encode_www_form_component(URI.encode_www_form_component(value)) }
      "userId=#{encode_twice.call(username)}&password=#{encode_twice.call(password)}&service=#{URI.encode_www_form_component(service)}&queryString=#{encode_twice.call(raw_query)}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"
    end

    def state
      result = @transport.status(@config.fetch('campus_interface'))
      raise Error, 'Campus device mismatch; refusing authentication' unless result[:device] == @config.fetch('campus_device')
      CampusDualwan.ipv4(result[:ip])
      result
    end

    def online?(device, directory)
      @checks.all? do |check|
        result = @transport.request(device, check.fetch('url'), directory)
        result[:code] == check.fetch('status') && (!check.key?('body') || result[:body].strip == check['body'])
      rescue Error
        false
      end
    end

    def authenticate(directory, now: Time.now.to_i)
      connection = state
      return :online if online?(connection[:device], directory)
      cooldown_file = File.join(directory, 'retry_at')
      return :backoff if File.exist?(cooldown_file) && File.read(cooldown_file).to_i > now
      probe = @transport.request(connection[:device], @checks.first.fetch('url'), directory)
      raw_query = query(probe[:headers] + "\n" + probe[:body])
      api = @origin.to_s + '/eportal/InterFace.do?method='
      page = @transport.request(connection[:device], api + 'pageInfo', directory,
                                body: URI.encode_www_form('queryString' => raw_query))
      raise Error, 'Portal pageInfo HTTP failure' unless page[:code] == 200
      info = JSON.parse(page[:body])
      raise Error, 'Invalid portal pageInfo object' unless info.is_a?(Hash)
      raise Error, 'Encrypted-password or captcha flow is not supported' unless info['passwordEncrypt'] == false && [nil, ''].include?(info['validCodeUrl'])
      username, password = %w[username_file password_file].map do |key|
        file = @config.fetch(key)
        CampusDualwan.secure_file!(file)
        value = File.read(file).sub(/\r?\n\z/, '')
        raise Error, 'Credential must be nonempty, single-line, and at most 4096 bytes' if value.empty? || value.bytesize > 4096 || value.match?(/[\r\n\x00]/)
        value
      end
      form = self.class.login_form(username, password, raw_query, @config.fetch('service', ''))
      result = @transport.request(connection[:device], api + 'login', directory, body: form)
      raise Error, 'Portal login HTTP failure' unless result[:code] == 200
      response = JSON.parse(result[:body])
      raise Error, 'Invalid portal login object' unless response.is_a?(Hash)
      accepted = response['result'] == 'success'
      unless accepted
        CampusDualwan.atomically_write(cooldown_file, (now + 900).to_s)
        return :rejected
      end
      if @renew_cidrs.any? { |cidr| cidr.include?(connection[:ip]) }
        @transport.renew(@config.fetch('campus_interface'))
        @transport.wait(8)
      else
        @transport.wait(3)
      end
      updated = state
      return :online if online?(updated[:device], directory)
      CampusDualwan.atomically_write(cooldown_file, (now + 60).to_s)
      :accepted_but_unverified
    rescue JSON::ParserError
      raise Error, 'Portal returned invalid JSON; contents suppressed'
    ensure
      # Reduce lifetime of references. This is not a promise of secure memory erasure.
      username = password = form = nil
    end
  end
end
