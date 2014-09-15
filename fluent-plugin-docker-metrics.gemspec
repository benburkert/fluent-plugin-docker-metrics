# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "fluent-plugin-docker-metrics"
  spec.version       = "0.0.1"
  spec.authors       = ["kiyoto", "palexandre"]
  spec.email         = ["kiyoto@treasure-data.com", "alexandre.philippe+github@gmail.com"]
  spec.summary       = %q{Fluentd plugin to collect Docker container metrics (Memory and network)}
  spec.homepage      = "https://github.com/palexandre/fluent-plugin-docker-metrics"
  spec.license       = "Apache License, Version 2.0"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake"
  spec.add_runtime_dependency "fluentd"
end
