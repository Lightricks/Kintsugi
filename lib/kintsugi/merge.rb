# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "json"
require "tmpdir"
require "tempfile"
require "xcodeproj"

require_relative "xcodeproj_extensions"
require_relative "apply_change_to_project"
require_relative "error"

module Kintsugi
  class << self
    # Resolves git conflicts of a pbxproj file specified by `project_file_path`.
    #
    # @param  [String] project_file_path
    #         Project to which to apply the changes.
    #
    # @param  [String] changes_output_path
    #         Path to where the changes to apply to the project are written in JSON format.
    #
    # @raise [ArgumentError]
    #        If the file extension is not `pbxproj`, or the file doesn't exist, or if no rebase,
    #        cherry-pick, or merge is in progress
    #
    # @raise [MergeError]
    #        If there was an error applying the change to the project.
    #
    # @return [void]
    def resolve_conflicts(project_file_path, changes_output_path)
      validate_project(project_file_path)

      base_project = copy_project_from_stage_number_to_temporary_directory(project_file_path, 1)
      ours_project = copy_project_from_stage_number_to_temporary_directory(project_file_path, 2)
      theirs_project = copy_project_from_stage_number_to_temporary_directory(project_file_path, 3)

      change = Xcodeproj::Differ.project_diff(theirs_project, base_project, :added, :removed)

      if changes_output_path
        File.write(changes_output_path, JSON.pretty_generate(change))
      end

      apply_change_and_copy_to_original_path(ours_project, change, project_file_path, base_project)
    end

    # Merges the changes done between `theirs_project_path` and `base_project_path` to the file at
    # `ours_project_path`. The files may not be at the original path, and therefore the
    # `original_project_path` is required in order for the project metadata to be written properly.
    #
    # @param  [String] base_project_path
    #         Path to the base version of the project.
    #
    # @param  [String] ours_project_path
    #         Path to ours version of the project.
    #
    # @param  [String] theirs_project_path
    #         Path to theirs version of the project.
    #
    # @param  [String] original_project_path
    #         Path to the original path of the file.
    #
    # @raise [MergeError]
    #        If there was an error applying the change to the project.
    #
    # @return [void]
    def three_way_merge(base_project_path, ours_project_path, theirs_project_path,
                        original_project_path)
      original_directory_name = File.basename(File.dirname(original_project_path))
      base_temporary_project =
        copy_project_to_temporary_path_in_directory_with_name(base_project_path,
                                                              original_directory_name)
      ours_temporary_project =
        copy_project_to_temporary_path_in_directory_with_name(ours_project_path,
                                                              original_directory_name)
      theirs_temporary_project =
        copy_project_to_temporary_path_in_directory_with_name(theirs_project_path,
                                                              original_directory_name)

      change =
        Xcodeproj::Differ.project_diff(theirs_temporary_project, base_temporary_project,
                                       :added, :removed)

      apply_change_and_copy_to_original_path(ours_temporary_project, change, ours_project_path,
                                             base_temporary_project)
    end

    private

    PROJECT_FILE_NAME = "project.pbxproj"

    def apply_change_and_copy_to_original_path(project, change, original_project_file_path,
                                               base_project)
      apply_change_to_project(project, change, base_project)
      project.save
      FileUtils.cp(File.join(project.path, PROJECT_FILE_NAME), original_project_file_path)
    end

    def validate_project(project_file_path)
      unless File.exist?(project_file_path)
        raise ArgumentError, "File '#{project_file_path}' doesn't exist"
      end

      if File.extname(project_file_path) != ".pbxproj"
        raise ArgumentError, "Wrong file extension, please provide file with extension .pbxproj\""
      end

      unless file_has_base_ours_and_theirs_versions?(project_file_path)
        raise ArgumentError, "File '#{project_file_path}' doesn't have conflicts, " \
          "or a 3-way merge is not possible."
      end
    end

    def copy_project_from_stage_number_to_temporary_directory(project_file_path, stage_number)
      project_directory_name = File.basename(File.dirname(project_file_path))
      temp_project_file_path = File.join(Dir.mktmpdir, project_directory_name, PROJECT_FILE_NAME)
      Dir.mkdir(File.dirname(temp_project_file_path))
      Dir.chdir(File.dirname(project_file_path)) do
        `git show :#{stage_number}:./#{PROJECT_FILE_NAME} > "#{temp_project_file_path}"`
      end
      Xcodeproj::Project.open(File.dirname(temp_project_file_path))
    end

    def copy_project_to_temporary_path_in_directory_with_name(project_file_path, directory_name)
      temp_directory_name = File.join(Dir.mktmpdir, directory_name)
      Dir.mkdir(temp_directory_name)
      temp_project_file_path = File.join(temp_directory_name, PROJECT_FILE_NAME)
      FileUtils.cp(project_file_path, temp_project_file_path)
      Xcodeproj::Project.open(File.dirname(temp_project_file_path))
    end

    def file_has_base_ours_and_theirs_versions?(file_path)
      Dir.chdir(`git -C "#{File.dirname(file_path)}" rev-parse --show-toplevel`.strip) do
        file_has_version_in_stage_numbers?(file_path, [1, 2, 3])
      end
    end

    def file_has_version_in_stage_numbers?(file_path, stage_numbers)
      file_absolute_path = File.absolute_path(file_path)
      actual_stage_numbers =
        `git ls-files -u -- "#{file_absolute_path}"`.split("\n").map do |git_file_status|
          git_file_status.split[2]
        end
      (stage_numbers - actual_stage_numbers.map(&:to_i)).empty?
    end
  end
end
