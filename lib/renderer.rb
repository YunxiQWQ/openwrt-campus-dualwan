# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 YunxiQWQ
# Extracted and parameterized from the deployed local configuration transformer.
require 'yaml'
require_relative 'common'

module CampusDualwan
  class Renderer
    def self.render(source, settings)
      config = YAML.safe_load(source, permitted_classes: [], aliases: false)
      raise Error, 'Expected a full static Mihomo configuration' unless config.is_a?(Hash) && config['proxies'].is_a?(Array) && config['rules'].is_a?(Array)
      raise Error, 'Remote proxy-providers are not supported; first create a local full configuration' unless (config['proxy-providers'] || {}).empty?
      device = CampusDualwan.identifier(settings.fetch('mobile_device'))
      mark = CampusDualwan.integer(settings.fetch('routing_mark'), 1..0xffffffff)
      hosts = config.fetch('hosts', {})
      raise Error, 'hosts must be a mapping' unless hosts.is_a?(Hash)
      prefixes = settings.fetch('metadata_name_prefixes', [])
      raise Error, 'Invalid metadata prefixes' unless prefixes.is_a?(Array) && prefixes.all? { |x| x.is_a?(String) && !x.empty? }
      metadata = config['proxies'].select { |p| p.is_a?(Hash) && prefixes.any? { |prefix| p['name'].to_s.start_with?(prefix) } }.map { |p| p['name'] }
      config['proxies'].reject! { |p| p.is_a?(Hash) && metadata.include?(p['name']) }
      raise Error, 'No real proxies remain' if config['proxies'].empty?
      config['proxies'].each do |proxy|
        raise Error, 'Invalid static proxy entry' unless proxy.is_a?(Hash) && proxy['name'].is_a?(String) && proxy['server'].is_a?(String) && proxy['type'].is_a?(String)
        raise Error, 'Built-in direct/dns policies cannot be treated as mobile nodes' if %w[direct dns reject].include?(proxy['type'])
        original = proxy['server']
        visited = []
        while hosts[proxy['server']].is_a?(String)
          raise Error, 'Cyclic server alias in hosts' if visited.include?(proxy['server'])
          visited << proxy['server']
          proxy['server'] = hosts[proxy['server']]
        end
        # Preserve explicit SNI; do not guess TLS identity after replacing an alias.
        tls = proxy['tls'] == true || %w[anytls trojan hysteria hysteria2 tuic].include?(proxy['type'])
        if tls && original != proxy['server'] && !proxy['sni'].is_a?(String)
          raise Error, 'An aliased TLS node needs explicit sni in the private source'
        end
        proxy['interface-name'] = device
        proxy['routing-mark'] = mark
        proxy['ip-version'] = 'ipv4'
      end
      (config['proxy-groups'] || []).each do |group|
        next unless group['proxies'].is_a?(Array)
        group['proxies'].reject! { |name| metadata.include?(name) }
        raise Error, 'A proxy group became empty' if group['proxies'].empty?
      end
      # A global mobile mark/interface would also affect DIRECT. Bind nodes only.
      config.delete('interface-name')
      config.delete('routing-mark')
      config['ipv6'] = false
      config['mode'] = 'rule'
      config['dns'] ||= {}
      raise Error, 'DNS override must be a mapping' unless settings.fetch('dns', {}).is_a?(Hash) && config['dns'].is_a?(Hash)
      config['dns'].merge!(settings.fetch('dns', {}))
      config['dns']['ipv6'] = false
      front = settings.fetch('direct_cidrs', []).map do |cidr|
        "IP-CIDR,#{CampusDualwan.ipv4(cidr, cidr: true)},DIRECT,no-resolve"
      end
      settings.fetch('direct_domains', []).each do |domain|
        raise Error, 'Invalid direct domain' unless domain.is_a?(String) && domain.match?(/\A[a-zA-Z0-9.-]+\z/)
        front << "DOMAIN-SUFFIX,#{domain},DIRECT"
      end
      config['rules'] = front + config['rules'].reject { |rule| front.include?(rule) }
      YAML.dump(config)
    rescue Psych::Exception
      raise Error, 'Invalid or unsupported YAML; contents suppressed'
    rescue KeyError
      raise Error, 'Missing renderer setting'
    end
  end
end
