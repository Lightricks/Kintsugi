# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "optparse"

require_relative "version"

module Kintsugi
  # Class resposible for creating the logic of various options for Kintsugi CLI.
  class CLI
    # Subcommands of Kintsugi CLI.
    attr_reader :subcommands

    # Root command Kintsugi CLI.
    attr_reader :root_command

    def initialize
      @subcommands = {
        "driver" => create_driver_subcommand
      }.freeze
      @root_command = create_root_command
    end

    private

    Command = Struct.new(:option_parser, :action, :description, keyword_init: true)

    def create_driver_subcommand
      driver_option_parser =
        OptionParser.new do |opts|
          opts.banner = "Usage: kintsugi driver BASE OURS THEIRS ORIGINAL_FILE_PATH\n" \
            "Uses Kintsugi as a Git merge driver. Parameters " \
            "should be the path to base version of the file, path to ours version, path to " \
            "theirs version, and the original file path."

          opts.on("-h", "--help", "Prints this help") do
            puts opts
            exit
          end
        end

      driver_action = lambda { |_, arguments, option_parser|
        if arguments.count != 4
          puts "Incorrect number of arguments to 'driver' subcommand\n\n"
          puts option_parser
          exit(1)
        end
        Kintsugi.three_way_merge(arguments[0], arguments[1], arguments[2], arguments[3])
      }

      Command.new(
        option_parser: driver_option_parser,
        action: driver_action,
        description: "3-way merge compatible with Git merge driver"
      )
    end

    def create_root_command
      root_option_parser = OptionParser.new do |opts|
        opts.banner = "Kintsugi, version #{Version::STRING}\n" \
                      "Copyright (c) 2021 Lightricks\n\n" \
                      "Usage: kintsugi <pbxproj_filepath> [options]\n" \
                      "       kintsugi <subcommand> [options]"

        opts.separator ""
        opts.on("--changes-output-path=PATH", "Path to which changes applied to the project are " \
                "written in JSON format. Used for debug purposes.")

        opts.on("-h", "--help", "Prints this help") do
          puts opts
          exit
        end

        opts.on("-v", "--version", "Prints version") do
          puts Version::STRING
          exit
        end

        subcommands_descriptions = @subcommands.map do |command_name, command|
          "    #{command_name}:    #{command.description}"
        end.join("\n")
        opts.on_tail("\nSUBCOMMANDS\n#{subcommands_descriptions}")
      end

      root_action = lambda { |options, arguments, option_parser|
        if arguments.count != 1
          puts "Incorrect number of arguments\n\n"
          puts option_parser
          exit(1)
        end

        project_file_path = File.expand_path(arguments[0])
        Kintsugi.resolve_conflicts(project_file_path, options[:"changes-output-path"])
        puts "Resolved conflicts successfully"
      }

      Command.new(
        option_parser: root_option_parser,
        action: root_action,
        description: nil
      )
    end
  end
end
