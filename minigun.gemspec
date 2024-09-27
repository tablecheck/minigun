# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'minigun/version'

Gem::Specification.new do |s|
  s.name        = 'minigun'
  s.version     = Minigun::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ['Johnny Shields']
  s.email       = 'johnny.shields@gmail.com'
  s.homepage    = 'https://github.com/tablecheck/minigun'
  s.summary     = 'A lightweight framework for rapid-fire batch job processing.'
  s.description = 'A lightweight framework for rapid-fire batch job processing.'
  s.license     = 'MIT'
  s.metadata = { 'rubygems_mfa_required' => 'true' }
  s.required_ruby_version = '>= 2.7'
  s.required_rubygems_version = '>= 1.3.6'

  s.files = Dir.glob('lib/**/*') + %w[LICENSE README.md]
  s.require_path = 'lib'
end
