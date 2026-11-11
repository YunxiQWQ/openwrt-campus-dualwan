#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
require_relative '../lib/network_fragment'
begin
  raise CampusDualwan::Error, 'Usage: render-network.rb SETTINGS.json (prints a candidate; does not apply it)' unless ARGV.size == 1
  puts CampusDualwan::NetworkFragment.render(CampusDualwan.json(ARGV.first))
rescue StandardError => error
  warn(error.is_a?(CampusDualwan::Error) ? error.message : 'Cannot read network settings')
  exit 1
end
