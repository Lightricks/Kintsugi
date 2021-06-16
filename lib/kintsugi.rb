# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "tmpdir"
require "tempfile"
require "xcodeproj"

require_relative "kintsugi/xcodeproj_extensions"
require_relative "kintsugi/apply_change_to_project"

module Kintsugi
  class << self
    # Resolves git conflicts of a pbxproj file specified by `project_file_path`.
    #
    # @param  [String] project_file_path
    #         Project to which to apply the changes.
    #
    # @param  [String] output_changes_path
    #         Path to where the changes to apply to the project are written in JSON format.
    #
    # @raise [ArgumentError]
    #        If the file extension is not `pbxproj` or the file doesn't exist
    #
    # @raise [RuntimeError]
    #        If no rebase, cherry-pick, or merge is in progress, or the project file couldn't be
    #        opened, or there was an error applying the change to the project.
    #
    # @return [void]
    def resolve_conflicts(project_file_path, changes_output_path)
      validate_project(project_file_path)

      project_in_temp_directory =
        open_project_of_current_commit_in_temporary_directory(project_file_path)

      change = change_of_conflicting_commit_with_parent(project_file_path)

      if changes_output_path
        File.write(changes_output_path, JSON.pretty_generate(change))
      end

      apply_change_to_project(project_in_temp_directory, change)

      project_in_temp_directory.save

      Dir.chdir(File.dirname(project_file_path)) do
        `git reset #{project_file_path}`
      end
      FileUtils.cp(File.join(project_in_temp_directory.path, "project.pbxproj"), project_file_path)

      # Some of the metadata in a `pbxproj` file include a part of the name of the directory it's
      # inside. The modified project is stored in a temporary directory and then copied to the
      # original path, therefore its metadata is incorrect. To fix this, the project at the original
      # path is opened and saved.
      Xcodeproj::Project.open(File.dirname(project_file_path)).save
    end

    private

    def validate_project(project_file_path)
      if File.extname(project_file_path) != ".pbxproj"
        raise ArgumentError, "Wrong file extension, please provide file with extension .pbxproj\""
      end

      unless File.exist?(project_file_path)
        raise ArgumentError, "File '#{project_file_path}' doesn't exist"
      end

      Dir.chdir(File.dirname(project_file_path)) do
        unless file_has_conflicts?(project_file_path)
          raise "File '#{project_file_path}' doesn't have conflicts"
        end
      end
    end

    def open_project_of_current_commit_in_temporary_directory(project_file_path)
      temp_project_file_path = File.join(Dir.mktmpdir, "project.pbxproj")
      Dir.chdir(File.dirname(project_file_path)) do
        `git show HEAD:./project.pbxproj > #{temp_project_file_path}`
      end
      Xcodeproj::Project.open(File.dirname(temp_project_file_path))
    end

    def file_has_conflicts?(file_path)
      file_absolute_path = File.absolute_path(file_path)
      `git diff --name-only --diff-filter=U`.split("\n").any? do |conficting_file_path|
        File.join(`git rev-parse --show-toplevel`.strip, conficting_file_path) == file_absolute_path
      end
    end

    def change_of_conflicting_commit_with_parent(project_file_path)
      Dir.chdir(File.dirname(project_file_path)) do
        conflicting_commit_project_file_path = File.join(Dir.mktmpdir, "project.pbxproj")
        `git show :3:./project.pbxproj > #{conflicting_commit_project_file_path}`

        conflicting_commit_parent_project_file_path = File.join(Dir.mktmpdir, "project.pbxproj")
        `git show :1:./project.pbxproj > #{conflicting_commit_parent_project_file_path}`

        conflicting_commit_project = Xcodeproj::Project.open(
          File.dirname(conflicting_commit_project_file_path)
        )
        conflicting_commit_parent_project =
          Xcodeproj::Project.open(File.dirname(conflicting_commit_parent_project_file_path))

        Xcodeproj::Differ.project_diff(conflicting_commit_project,
                                       conflicting_commit_parent_project, :added, :removed)
      end
    end
  end
end
