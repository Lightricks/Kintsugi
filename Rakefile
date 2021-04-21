# frozen_string_literal: true

# Copyright (c) 2020 Lightricks. All rights reserved.
# Created by Ben Yohay.

require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new(:rubocop)

task default: %i[rubocop spec]
