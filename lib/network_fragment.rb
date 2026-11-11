# SPDX-License-Identifier: GPL-3.0-only
# Parameterized from the local OpenWrt UCI policy, including loopback guard.
require_relative 'common'

module CampusDualwan
  class NetworkFragment
    def self.render(config)
      mobile = CampusDualwan.identifier(config.fetch('mobile_interface'))
      lan = CampusDualwan.identifier(config.fetch('lan_interface'))
      table = CampusDualwan.integer(config.fetch('table'), 1..252)
      priority = CampusDualwan.integer(config.fetch('priority_start'), 1000..30000)
      mark = CampusDualwan.integer(config.fetch('routing_mark'), 1..0xffffffff)
      gateway = CampusDualwan.ipv4(config.fetch('mobile_gateway'))
      mobile_cidr = CampusDualwan.ipv4(config.fetch('mobile_cidr'), cidr: true)
      raise Error, 'Gateway must belong to mobile_cidr' unless IPAddr.new(mobile_cidr).include?(gateway)
      nodes = config.fetch('node_ipv4', []).map { |ip| CampusDualwan.ipv4(ip) }.uniq
      raise Error, 'At most 100 fixed node endpoints are supported' if nodes.size > 100
      parts = ["# Generated candidate fragment. MERGE after review; do not replace /etc/config/network."]
      section = lambda do |type, name, options|
        parts << "config #{type} 'cdw_#{name}'\n" + options.map { |key, value| "\toption #{key} '#{value}'" }.join("\n")
      end
      section.call('route', 'mobile_link', {interface: mobile, target: mobile_cidr, table: table})
      config.fetch('lan_cidrs').each_with_index do |cidr, i|
        section.call('route', "lan_#{i}", {interface: lan, target: CampusDualwan.ipv4(cidr, cidr: true), table: table})
      end
      section.call('route', 'mobile_default', {interface: mobile, target: '0.0.0.0/0', gateway: gateway, table: table, metric: 10})
      # Keep this route attached to loopback, NOT mobile: it must survive mobile down.
      section.call('route', 'guard', {interface: 'loopback', target: '0.0.0.0/0', type: 'unreachable', table: table, metric: 32760})
      section.call('rule', 'mark', {mark: format('0x%x/0xffffffff', mark), lookup: table, priority: priority})
      section.call('rule', 'output', {out: mobile, lookup: table, priority: priority + 1})
      section.call('rule', 'source', {src: mobile_cidr, lookup: table, priority: priority + 2})
      nodes.each_with_index do |ip, i|
        section.call('rule', "node_#{i}", {dest: "#{ip}/32", lookup: table, priority: priority + 3 + i})
      end
      parts.join("\n\n") + "\n"
    rescue KeyError
      raise Error, 'Missing network setting'
    end
  end
end
