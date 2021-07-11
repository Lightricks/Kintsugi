# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "json"
require "rspec"
require "tempfile"
require "tmpdir"

require "kintsugi/apply_change_to_project"

require_relative "be_equivalent_to_project"

describe Kintsugi, :apply_change_to_project do
  let(:temporary_directories_paths) { [] }
  let(:base_project_path) { make_temp_directory("base", ".xcodeproj") }
  let(:base_project) { Xcodeproj::Project.new(base_project_path) }

  before do
    base_project.save
  end

  after do
    temporary_directories_paths.each do |directory_path|
      FileUtils.remove_entry(directory_path)
    end
  end

  it "adds new target" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    theirs_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds new subproject" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    add_new_subproject_to_project(theirs_project, "foo", "foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
  end

  # Checks that the order the changes are applied in is correct.
  it "adds new subproject and reference to its framework" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    add_new_subproject_to_project(theirs_project, "foo", "foo")

    target = theirs_project.new_target("com.apple.product-type.library.static", "foo", :ios)
    target.frameworks_build_phase.add_file_reference(
      theirs_project.root_object.project_references[0][:product_group].children[0]
    )

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
  end

  describe "file related changes" do
    let(:filepath) { "foo" }

    before do
      base_project.main_group.new_reference(filepath)
      base_project.save
    end

    it "moves file to another group" do
      base_project.main_group.find_subpath("new_group", true)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.move(new_group)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file to new group" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.main_group.find_subpath("new_group", true).new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file with include in index and last known file type as nil" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project.main_group.new_reference("#{filepath}.h")
      file_reference.include_in_index = nil
      file_reference.last_known_file_type = nil

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "renames file" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.path = "newFoo"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes file" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.main_group.find_file_by_path(filepath).remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes build files of a removed file" do
      target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
      target.source_build_phase.add_file_reference(
        base_project.main_group.find_file_by_path(filepath)
      )
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.build_files.each do |build_file|
        build_file.referrers.each do |referrer|
          referrer.remove_build_file(build_file)
        end
      end
      file_reference.remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file inside a group that has a path on filesystem" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      new_group = theirs_project.main_group.find_subpath("new_group", true)
      new_group.path = "some_path"
      new_group.name = nil
      new_group.new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "handles subfile changes" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"
      theirs_project.main_group.find_file_by_path(filepath).include_in_index = "0"
      theirs_project.main_group.find_file_by_path(filepath).fileEncoding = "4"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "handles moved file to an existing group with a different path on filesystem" do
      base_project.main_group.find_subpath("new_group", true).path = "some_path"

      base_project.save
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      new_group = theirs_project.main_group.find_subpath("new_group")

      theirs_project.main_group.find_file_by_path(filepath).move(new_group)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    describe "dealing with unexpected change" do
      it "ignores change to a file whose containing group doesn't exist" do
        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.main_group.remove_from_project
        ours_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project_before_applying_changes = create_copy_of_project(ours_project.path, "ours")

        described_class.apply_change_to_project(ours_project, changes_to_apply)
        ours_project.save

        expect(ours_project).to be_equivalent_to_project(ours_project_before_applying_changes)
      end

      it "ignores change to a file that doesn't exist" do
        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.main_group.find_file_by_path(filepath).remove_from_project
        ours_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project_before_applying_changes = create_copy_of_project(ours_project.path, "ours")

        described_class.apply_change_to_project(ours_project, changes_to_apply)
        ours_project.save

        expect(ours_project).to be_equivalent_to_project(ours_project_before_applying_changes)
      end

      it "ignores removal of a file whose group doesn't exist" do
        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.main_group.remove_from_project
        ours_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).remove_from_project

        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project_before_applying_changes = create_copy_of_project(ours_project.path, "ours")

        described_class.apply_change_to_project(ours_project, changes_to_apply)
        ours_project.save

        expect(ours_project).to be_equivalent_to_project(ours_project_before_applying_changes)
      end

      it "ignores removal of non-existent file" do
        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.main_group.find_file_by_path(filepath).remove_from_project

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).remove_from_project

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(ours_project, changes_to_apply)
        ours_project.save

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end
    end
  end

  describe "target related changes" do
    let!(:target) { base_project.new_target("com.apple.product-type.library.static", "foo", :ios) }

    before do
      base_project.save
    end

    it "changes framework from file reference to reference proxy" do
      framework_filename = "baz"

      file_reference = base_project.main_group.new_reference(framework_filename)
      base_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      add_new_subproject_to_project(base_project, "subproj", framework_filename)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.files[0].remove_from_project
      build_phase.add_file_reference(
        theirs_project.root_object.project_references[0][:product_group].children[0]
      )

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes framework from reference proxy to file reference" do
      framework_filename = "baz"

      add_new_subproject_to_project(base_project, "subproj", framework_filename)
      base_project.targets[0].frameworks_build_phase.add_file_reference(
        base_project.root_object.project_references[0][:product_group].children[0]
      )

      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      file_reference = theirs_project.main_group.new_reference(framework_filename)
      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.files[-1].remove_from_project
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds remote ref to reference proxy" do
      framework_filename = "baz"

      add_new_subproject_to_project(base_project, "subproj", framework_filename)
      build_file = base_project.targets[0].frameworks_build_phase.add_file_reference(
        base_project.root_object.project_references[0][:product_group].children[0]
      )
      container_proxy = build_file.file_ref.remote_ref
      build_file.file_ref.remote_ref = nil

      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].frameworks_build_phase.files[-1].file_ref.remote_ref =
        container_proxy

      changes_to_apply = get_diff(theirs_project, base_project)

      changes_to_apply["rootObject"].delete("projectReferences")

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds subproject target and adds reference to it" do
      framework_filename = "baz"
      subproject = add_new_subproject_to_project(base_project, "subproj", framework_filename)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      subproject.new_target("com.apple.product-type.library.static", "bari", :ios)

      theirs_project.root_object.project_references[0][:product_group] <<
        create_reference_proxy_from_product_reference(theirs_project,
                                                      theirs_project.root_object.project_references[0][:project_ref],
                                                      subproject.products_group.files[-1])

      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.add_file_reference(
        theirs_project.root_object.project_references[0][:product_group].children[-1]
      )

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds new build file" do
      base_project.main_group.new_reference("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "adds file reference to build file" do
      file_reference = base_project.main_group.new_reference("bar")

      build_file = base_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)
      build_file.file_ref = nil

      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      theirs_project.targets[0].frameworks_build_phase.files[-1].file_ref = file_reference

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "ignores build file without file reference" do
      base_project.main_group.new_reference("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      build_file =
        theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)
      build_file.file_ref = nil

      changes_to_apply = get_diff(theirs_project, base_project)

      other_project = create_copy_of_project(base_project.path, "other")
      described_class.apply_change_to_project(other_project, changes_to_apply)
      other_project.save

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "adds new build rule" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      build_rule = theirs_project.new(Xcodeproj::Project::PBXBuildRule)
      build_rule.compiler_spec = "com.apple.compilers.proxy.script"
      build_rule.file_type = "pattern.proxy"
      build_rule.file_patterns = "*.json"
      build_rule.is_editable = "1"
      build_rule.input_files = [
        "$(DERIVED_FILE_DIR)/$(arch)/${INPUT_FILE_BASE}.json"
      ]
      build_rule.output_files = [
        "$(DERIVED_FILE_DIR)/$(arch)/${INPUT_FILE_BASE}.h",
        "$(DERIVED_FILE_DIR)/$(arch)/${INPUT_FILE_BASE}.mm"
      ]
      build_rule.script = "foo"
      theirs_project.targets[0].build_rules << build_rule

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "adds new build setting" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = [
          "$(SRCROOT)/../Foo",
          "$(SRCROOT)/../Bar"
        ]
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds values to existing build setting" do
      base_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = [
          "$(SRCROOT)/../Foo"
        ]
      end

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = [
          "$(SRCROOT)/../Foo",
          "$(SRCROOT)/../Bar"
        ]
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes build setting" do
      base_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = [
          "$(SRCROOT)/../Foo",
          "$(SRCROOT)/../Bar"
        ]
      end

      base_project.save
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = nil
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds build phases" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].new_shell_script_build_phase("bar")
      theirs_project.targets[0].source_build_phase
      theirs_project.targets[0].headers_build_phase
      theirs_project.targets[0].frameworks_build_phase
      theirs_project.targets[0].resources_build_phase
      theirs_project.targets[0].new_copy_files_build_phase("baz")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes build phase" do
      base_project.targets[0].new_shell_script_build_phase("bar")

      base_project.save
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].shell_script_build_phases[0].remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "ignores localizations in build settings added to existing localization files" do
      variant_group = base_project.main_group.new_variant_group("foo.strings")
      file = variant_group.new_reference("Base")
      file.last_known_file_type = "text.plist.strings"
      target.resources_build_phase.add_file_reference(variant_group)

      base_project.save
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_variant_group = theirs_project.main_group.find_subpath("foo.strings")
      theirs_variant_group.new_reference("en")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds target dependency" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)

      base_project.save
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[1].add_dependency(theirs_project.targets[0])

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes value of a string build setting" do
      base_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["GCC_PREFIX_HEADER"] = "foo"
      end

      base_project.save
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["GCC_PREFIX_HEADER"] = "bar"
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds build settings to new target" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.new_target("com.apple.product-type.library.static", "bar", :ios)

      theirs_project.targets[1].build_configurations.each do |configuration|
        configuration.build_settings["GCC_PREFIX_HEADER"] = "baz"
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds base configuration reference to new target" do
      base_project.main_group.new_reference("baz")

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      configuration_reference = theirs_project.main_group.find_subpath("baz")
      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.base_configuration_reference = configuration_reference
      end

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      base_project.save

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end
  end

  it "adds known regions" do
    base_project.save
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.known_regions += ["en"]

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes known regions" do
    base_project.root_object.known_regions += ["en"]

    base_project.save
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.known_regions = []

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes even if target attributes don't exist" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes of new target" do
    base_project.root_object.attributes["TargetAttributes"] = {}
    base_project.save

    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes of existing target" do
    base_project.root_object.attributes["TargetAttributes"] = {"foo" => {}}
    base_project.save

    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes attribute target changes" do
    base_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}
    base_project.save

    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.attributes["TargetAttributes"]["foo"] = {}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes attribute target changes from a project it was removed from already" do
    base_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}
    base_project.save

    theirs_project = create_copy_of_project(base_project.path, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"]["foo"] = {}

    ours_project = create_copy_of_project(base_project.path, "ours")
    ours_project.root_object.attributes["TargetAttributes"]["foo"] = {}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(ours_project, changes_to_apply)
    ours_project.save

    expect(ours_project).to be_equivalent_to_project(theirs_project)
  end

  it "identifies subproject added in separate times" do
    framework_filename = "baz"

    subproject = new_subproject("subproj", framework_filename)

    add_existing_subproject_to_project(base_project, subproject, framework_filename)
    base_project.save

    theirs_project_path = make_temp_directory("theirs", ".xcodeproj")
    theirs_project = Xcodeproj::Project.new(theirs_project_path)
    add_existing_subproject_to_project(theirs_project, subproject, framework_filename)
    theirs_project.save
    ours_project = create_copy_of_project(theirs_project_path, "other_theirs")

    subproject.new_target("com.apple.product-type.library.static", "bari", :ios)
    ours_project.root_object.project_references[0][:product_group] <<
      create_reference_proxy_from_product_reference(theirs_project,
                                                    theirs_project.root_object.project_references[0][:project_ref],
                                                    subproject.products_group.files[-1])

    changes_to_apply = get_diff(ours_project, theirs_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)
    base_project.save

    expect(base_project).to be_equivalent_to_project(ours_project, ignore_keys: ["containerPortal"])
  end

  it "adds localization files" do
    base_project_path = make_temp_directory("base", ".xcodeproj")
    base_project = Xcodeproj::Project.new(base_project_path)
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    base_project.save
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    variant_group = theirs_project.main_group.new_variant_group("foo.strings")
    variant_group.new_reference("Base").last_known_file_type = "text.plist.strings"
    theirs_project.targets[0].resources_build_phase.add_file_reference(variant_group)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  def create_copy_of_project(project_path, new_project_prefix)
    copied_project_path = make_temp_directory(new_project_prefix, ".xcodeproj")
    FileUtils.cp(File.join(project_path, "project.pbxproj"), copied_project_path)
    Xcodeproj::Project.open(copied_project_path)
  end

  def get_diff(first_project, second_project)
    Xcodeproj::Differ.project_diff(first_project, second_project, :added, :removed)
  end

  def add_new_subproject_to_project(project, subproject_name, subproject_product_name)
    subproject = new_subproject(subproject_name, subproject_product_name)
    add_existing_subproject_to_project(project, subproject, subproject_product_name)
    subproject
  end

  def new_subproject(subproject_name, subproject_product_name)
    subproject_path = make_temp_directory(subproject_name, ".xcodeproj")
    subproject = Xcodeproj::Project.new(subproject_path)
    subproject.new_target("com.apple.product-type.library.static", subproject_product_name, :ios)
    subproject.save

    subproject
  end

  def add_existing_subproject_to_project(project, subproject, subproject_product_name)
    subproject_reference = project.new_file(subproject.path, :built_products)

    # Workaround for a bug in xcodeproj: https://github.com/CocoaPods/Xcodeproj/issues/678
    project.main_group.find_subpath("Products").children.find do |file_reference|
      # The name of the added file reference is equivalent to the name of the product.
      file_reference.path == subproject_product_name
    end.remove_from_project

    project.root_object.project_references[0][:product_group] =
      project.new(Xcodeproj::Project::PBXGroup)
    project.root_object.project_references[0][:product_group].name = "Products"
    project.root_object.project_references[0][:product_group] <<
      create_reference_proxy_from_product_reference(project, subproject_reference,
                                                    subproject.products_group.files[0])
  end

  def create_reference_proxy_from_product_reference(project, subproject_reference,
      product_reference)
    container_proxy = project.new(Xcodeproj::Project::PBXContainerItemProxy)
    container_proxy.container_portal = subproject_reference.uuid
    container_proxy.proxy_type = Xcodeproj::Constants::PROXY_TYPES[:reference]
    container_proxy.remote_global_id_string = product_reference.uuid
    container_proxy.remote_info = subproject_reference.name

    reference_proxy = project.new(Xcodeproj::Project::PBXReferenceProxy)
    extension = File.extname(product_reference.path)[1..-1]
    reference_proxy.file_type = Xcodeproj::Constants::FILE_TYPES_BY_EXTENSION[extension]
    reference_proxy.path = product_reference.path
    reference_proxy.remote_ref = container_proxy
    reference_proxy.source_tree = 'BUILT_PRODUCTS_DIR'

    reference_proxy
  end

  def make_temp_directory(directory_prefix, directory_extension)
    directory_path = Dir.mktmpdir([directory_prefix, directory_extension])
    temporary_directories_paths << directory_path
    directory_path
  end
end
