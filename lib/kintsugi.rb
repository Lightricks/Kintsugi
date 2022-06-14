# frozen_string_literal: true

# Copyright (c) 2022 Lightricks. All rights reserved.
# Created by Ben Yohay.

require_relative "kintsugi/cli"
require_relative "kintsugi/error"
require_relative "kintsugi/merge"

module Kintsugi
  class << self
    def run(arguments)
      first_argument = arguments[0]
      cli = CLI.new
      command =
        if name_of_subcommand?(cli.subcommands, first_argument)
          arguments.shift
          cli.subcommands[first_argument]
        else
          cli.root_command
        end

      options = parse_options!(command, arguments)

      begin
        command.action.call(options, arguments)
      rescue ArgumentError => e
        puts "#{e.class}: #{e}"
        raise
      rescue Kintsugi::MergeError => e
        puts e
        raise
      end
    end

    private

    def parse_options!(command, arguments)
      options = {}
      command.option_parser.parse!(arguments, into: options)
      options
    end

    def name_of_subcommand?(subcommands, argument)
      subcommands.include?(argument)
    end
  end
end
