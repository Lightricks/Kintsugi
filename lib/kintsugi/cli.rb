# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "fileutils"
require "optparse"

require_relative "settings"
require_relative "version"

module Kintsugi
  # Class resposible for creating the logic of various options for Kintsugi CLI.
  class CLI
    # Subcommands of Kintsugi CLI.
    attr_reader :subcommands

    # Root command of Kintsugi CLI.
    attr_reader :root_command

    def initialize
      @subcommands = {
        "driver" => create_driver_subcommand,
        "install-driver" => create_install_driver_subcommand,
        "uninstall-driver" => create_uninstall_driver_subcommand
      }.freeze
      @root_command = create_root_command
    end

    private

    Command = Struct.new(:option_parser, :action, :description, keyword_init: true)

    def create_driver_subcommand
      option_parser = create_base_option_parser
      option_parser.banner = "Usage: kintsugi driver BASE OURS THEIRS ORIGINAL_FILE_PATH " \
          "[options]\n" \
          "Uses Kintsugi as a Git merge driver. Parameters " \
          "should be the path to base version of the file, path to ours version, path to " \
          "theirs version, and the original file path."

      driver_action = lambda { |options, arguments|
        if arguments.count != 4
          puts "Incorrect number of arguments to 'driver' subcommand\n\n"
          puts option_parser
          exit(1)
        end

        update_settings(options)

        Kintsugi.three_way_merge(arguments[0], arguments[1], arguments[2], arguments[3])
        warn "\e[32mKintsugi auto-merged #{arguments[3]}\e[0m"
      }

      Command.new(
        option_parser: option_parser,
        action: driver_action,
        description: "3-way merge compatible with Git merge driver"
      )
    end

    def create_install_driver_subcommand
      option_parser = create_base_option_parser
      option_parser.banner = "Usage: kintsugi install-driver [driver-options]\n" \
          "Installs Kintsugi as a Git merge driver globally. `driver-options` will be passed " \
          "to `kintsugi driver`."

      action = lambda { |options, arguments|
        if arguments.count != 0
          puts "Incorrect number of arguments to 'install-driver' subcommand\n\n"
          puts option_parser
          exit(1)
        end

        if `which kintsugi`.chomp.empty?
          puts "Can only install Kintsugi globally if Kintsugi is in your PATH"
          exit(1)
        end

        driver_options = extract_driver_options(options, option_parser)

        install_kintsugi_driver_globally(driver_options)
        puts "Done! 🪄"
      }

      Command.new(
        option_parser: option_parser,
        action: action,
        description: "Installs Kintsugi as a Git merge driver globally"
      )
    end

    def extract_driver_options(options, option_parser)
      options.map do |option_name, option_value|
        switch = option_parser.top.search(:long, option_name.to_s)
        prefix = "--"
        if switch.nil?
          switch = option_parser.top.search(:short, option_name.to_s)
          prefix = "-"
        end
        case switch
        when OptionParser::Switch::NoArgument
          [prefix + option_name.to_s]
        when NilClass
          puts "Invalid flag #{option_name} passed to 'install-driver' subcommand\n\n"
          puts option_parser
          exit(1)
        else
          [prefix + option_name.to_s, option_value]
        end
      end.flatten
    end

    def install_kintsugi_driver_globally(options)
      `git config --global merge.kintsugi.name "Kintsugi driver"`
      kintsugi_command = "kintsugi driver %O %A %B %P #{options.join(" ")}".rstrip
      `git config --global merge.kintsugi.driver "#{kintsugi_command}"`

      attributes_file_path = global_attributes_file_path
      FileUtils.mkdir_p(File.dirname(attributes_file_path))

      merge_using_kintsugi_line = "'*.pbxproj merge=kintsugi'"
      `grep -sqxF #{merge_using_kintsugi_line} "#{attributes_file_path}" \
        || echo #{merge_using_kintsugi_line} >> "#{attributes_file_path}"`
    end

    def global_attributes_file_path
      # The logic to decide the path to the global attributes file is described at:
      # https://git-scm.com/docs/gitattributes.
      config_attributes_file_path = `git config --global core.attributesfile`.chomp
      return config_attributes_file_path unless config_attributes_file_path.empty?

      if ENV["XDG_CONFIG_HOME"].nil? || ENV["XDG_CONFIG_HOME"].empty?
        File.join(ENV["HOME"], ".config/git/attributes")
      else
        File.join(ENV["XDG_CONFIG_HOME"], "git/attributes")
      end
    end

    def create_uninstall_driver_subcommand
      option_parser =
        OptionParser.new do |opts|
          opts.banner = "Usage: kintsugi uninstall-driver\n" \
            "Uninstalls Kintsugi as a Git merge driver that was previously installed globally."

          opts.on("-h", "--help", "Prints this help") do
            puts opts
            exit
          end
        end

      action = lambda { |_, arguments|
        if arguments.count != 0
          puts "Incorrect number of arguments to 'uninstall-driver' subcommand\n\n"
          puts option_parser
          exit(1)
        end

        uninstall_kintsugi_driver_globally
        puts "Done!"
      }

      Command.new(
        option_parser: option_parser,
        action: action,
        description: "Uninstalls Kintsugi as a Git merge driver that was previously installed " \
                     "globally."
      )
    end

    def uninstall_kintsugi_driver_globally
      `git config --global --unset merge.kintsugi.name`
      `git config --global --unset merge.kintsugi.driver`

      attributes_file_path = global_attributes_file_path
      return unless File.exist?(attributes_file_path)

      `sed -i '' '/\*.pbxproj\ merge=kintsugi/d' "#{attributes_file_path}"`
    end

    def create_root_command
      option_parser = create_base_option_parser
      option_parser.banner = "Kintsugi, version #{Version::STRING}\n" \
          "Copyright (c) 2021 Lightricks\n\n" \
          "Usage: kintsugi <pbxproj_filepath> [options]\n" \
          "       kintsugi <subcommand> [options]"

      option_parser.on("-v", "--version", "Prints version") do
        puts Version::STRING
        exit
      end

      option_parser.on("--changes-output-path=PATH", "Path to which changes applied to the " \
          "project are written in JSON format. Used for debug purposes.")

      option_parser.on_tail("\nSUBCOMMANDS\n#{subcommands_descriptions(subcommands)}")

      root_action = lambda { |options, arguments|
        if arguments.count != 1
          puts "Incorrect number of arguments\n\n"
          puts option_parser
          exit(1)
        end

        update_settings(options)

        project_file_path = File.expand_path(arguments[0])
        Kintsugi.resolve_conflicts(project_file_path, options[:"changes-output-path"])
        puts "Resolved conflicts successfully"
      }

      Command.new(
        option_parser: option_parser,
        action: root_action,
        description: nil
      )
    end

    def create_base_option_parser
      OptionParser.new do |opts|
        opts.separator ""

        opts.on("-h", "--help", "Prints this help") do
          puts opts
          exit
        end

        opts.on("--allow-duplicates", "Allow to add duplicates of the same entity")

        opts.on("--interactive-resolution=FLAG", TrueClass, "In case a conflict that requires " \
                "human decision to resolve, show an interactive prompt with choices to resolve it")
      end
    end

    def update_settings(options)
      if options[:"allow-duplicates"]
        Settings.allow_duplicates = true
      end

      unless options[:"interactive-resolution"].nil?
        Settings.interactive_resolution = options[:"interactive-resolution"]
      end
    end

    def subcommands_descriptions(subcommands)
      longest_subcommand_length = subcommands.keys.map(&:length).max + 4
      format_string = "    %-#{longest_subcommand_length}s%s"
      subcommands.map do |command_name, command|
        format(format_string, "#{command_name}:", command.description)
      end.join("\n")
    end
  end
end
