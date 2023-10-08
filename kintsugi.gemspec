# frozen_string_literal: true

require_relative "lib/kintsugi/version"

Gem::Specification.new do |spec|
  spec.name          = "kintsugi"
  spec.version       = Kintsugi::Version::STRING
  spec.authors       = ["Ben Yohay"]
  spec.email         = ["ben@lightricks.com"]
  spec.required_ruby_version = ">= 2.5.0"
  spec.description =
    %q(
      Kintsugi resolves conflicts in .pbxproj files, with the aim to resolve 99.9% of the conflicts
      automatically.
    )
  spec.summary       = %q(pbxproj files git conflicts solver)
  spec.homepage      = "https://github.com/Lightricks/Kintsugi"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(spec)/})
  spec.require_paths = ["lib"]

  spec.add_dependency "tty-prompt", "~> 0"
  spec.add_dependency "xcodeproj", ">= 1.19.0", "<= 1.23.0"

  spec.add_development_dependency "git", "~> 1.11"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.9"
  spec.add_development_dependency "rubocop", "1.12.0"
  spec.add_development_dependency "rubocop-rspec", "2.2.0"
  spec.add_development_dependency "simplecov", "~> 0.21"
end
