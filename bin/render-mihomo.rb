#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
require_relative '../lib/renderer'
begin
  raise CampusDualwan::Error, 'Usage: render-mihomo.rb SOURCE.yaml SETTINGS.json OUTPUT.yaml' unless ARGV.size == 3
  source, settings, output = ARGV
  raise CampusDualwan::Error, 'Output must differ from both input paths' if [source, settings].map { |p| File.expand_path(p) }.include?(File.expand_path(output))
  CampusDualwan.secure_file!(source)
  content = CampusDualwan::Renderer.render(File.read(source), CampusDualwan.json(settings))
  CampusDualwan.atomically_write(output, content)
  puts 'Rendered private configuration. Review it and run mihomo -t before loading.'
rescue StandardError => error
  warn(error.is_a?(CampusDualwan::Error) ? error.message : 'File operation failed; private details suppressed')
  exit 1
end
