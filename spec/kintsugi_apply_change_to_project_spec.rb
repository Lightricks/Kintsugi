# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "json"
require "rspec"
require "tempfile"
require "tmpdir"

require "kintsugi/apply_change_to_project"
require "kintsugi/error"

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

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds new aggregate target" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    theirs_project.new_aggregate_target("foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds package reference" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.package_references <<
      create_remote_swift_package_reference(theirs_project)

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds new subproject" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    add_new_subproject_to_project(theirs_project, "foo", "foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

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

    expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
  end

  it "raises if adding subproject whose file reference isn't found" do
    ours_project = create_copy_of_project(base_project.path, "ours")

    add_new_subproject_to_project(base_project, "foo", "foo")
    base_project.save

    theirs_project = create_copy_of_project(base_project.path, "theirs")

    base_project.root_object.project_references.pop

    changes_to_apply = get_diff(theirs_project, base_project)

    expect {
      described_class.apply_change_to_project(ours_project, changes_to_apply)
    }.to raise_error(Kintsugi::MergeError)
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

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "raises when a file is split into two" do
      base_project.main_group.find_subpath("new_group", true)
      base_project.main_group.find_subpath("new_group2", true)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.move(new_group)
      theirs_project.main_group.find_subpath("new_group2").new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      expect {
        described_class.apply_change_to_project(base_project, changes_to_apply)
      }.to raise_error(Kintsugi::MergeError)
    end

    it "adds file to new group" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.main_group.find_subpath("new_group", true).new_reference(filepath)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes group" do
      base_project.main_group.find_subpath("new_group", true)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project["new_group"].remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds file with include in index and last known file type as nil" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project.main_group.new_reference("#{filepath}.h")
      file_reference.include_in_index = nil
      file_reference.last_known_file_type = nil

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

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

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes simple attribute of a file that has a build file" do
      target = base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      file_reference = base_project.main_group.find_file_by_path(filepath)
      target.frameworks_build_phase.add_file_reference(file_reference)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project.main_group.find_file_by_path(filepath)
      file_reference.include_in_index = "4"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

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

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "handles subfile changes" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.main_group.find_file_by_path(filepath).explicit_file_type = "bar"
      theirs_project.main_group.find_file_by_path(filepath).include_in_index = "0"
      theirs_project.main_group.find_file_by_path(filepath).fileEncoding = "4"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

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

        expect(ours_project).to be_equivalent_to_project(ours_project_before_applying_changes)
      end

      it "ignores removal of non-existent file" do
        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.main_group.find_file_by_path(filepath).remove_from_project

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.main_group.find_file_by_path(filepath).remove_from_project

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(ours_project, changes_to_apply)

        expect(ours_project).to be_equivalent_to_project(theirs_project)
      end
    end
  end

  describe "target related changes" do
    let!(:target) { base_project.new_target("com.apple.product-type.library.static", "foo", :ios) }

    before do
      base_project.save
    end

    it "moves file that is referenced by a target from main group to a new group" do
      file_reference = base_project.main_group.new_reference("bar")
      base_project.targets[0].source_build_phase.add_file_reference(file_reference)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      new_group = theirs_project.main_group.find_subpath("new_group", true)
      file_reference = theirs_project.main_group.find_file_by_path("bar")
      file_reference.move(new_group)
      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "moves file that is referenced by a target from a group to the main group" do
      file_reference = base_project.main_group.find_subpath("new_group", true).new_reference("bar")
      base_project.targets[0].source_build_phase.add_file_reference(file_reference)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project["new_group/bar"]
      file_reference.move(theirs_project.main_group)
      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "changes framework from file reference to reference proxy" do
      framework_filename = "baz"

      file_reference = base_project.main_group.new_reference(framework_filename)
      base_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      add_new_subproject_to_project(base_project, "subproj", framework_filename)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.files.find { |build_file| build_file.display_name == "baz" }.remove_from_project
      build_phase.add_file_reference(
        theirs_project.root_object.project_references[0][:product_group].children[0]
      )

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds package product dependency to target" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.targets[0].package_product_dependencies <<
        create_swift_package_product_dependency(theirs_project)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

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

      file_reference = theirs_project.main_group.new_reference("bar")
      file_reference.name = framework_filename
      build_phase = theirs_project.targets[0].frameworks_build_phase
      build_phase.files[-1].remove_from_project
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)
      # This verifies we haven't created a new file reference instead of reusing the one in the
      # hierarchy.
      base_project.files[-1].name = "foo"
      theirs_project.files[-1].name = "foo"

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

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "adds product ref to build file" do
      base_project.main_group.new_reference("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      file_reference = theirs_project.main_group.files.find { |file| file.display_name == "bar" }
      build_file =
        theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)
      build_file.product_ref =
        create_swift_package_product_dependency(theirs_project)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    it "adds build file to a file reference that already exists" do
      base_project.main_group.new_reference("bar")
      base_project.main_group.new_reference("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_file_reference = theirs_project.main_group.files.find do |file|
        !file.referrers.find { |referrer| referrer.is_a?(Xcodeproj::Project::PBXBuildFile) } &&
          file.display_name == "bar"
      end
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(theirs_file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
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

      expect(base_project).to be_equivalent_to_project(theirs_project, ignore_keys: ["containerPortal"])
    end

    describe "build settings" do
      it "adds new string build setting" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "$(SRCROOT)/../Bar"
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds new array build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = {}
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

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds new hash build setting" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = [
            "$(SRCROOT)/../Foo",
            "$(SRCROOT)/../Bar"
          ]
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds values to existing array build setting" do
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

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "adds array value to an existing string if no removed value" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
        end
        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        described_class.apply_change_to_project(ours_project, changes_to_apply)

        expected_project = create_copy_of_project(base_project.path, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo baz]
        end
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end

      it "adds string value to existing array value if no removed value" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end
        changes_to_apply = get_diff(theirs_project, base_project)

        ours_project = create_copy_of_project(base_project.path, "ours")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
        end

        described_class.apply_change_to_project(ours_project, changes_to_apply)

        expected_project = create_copy_of_project(base_project.path, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo baz]
        end
        expect(ours_project).to be_equivalent_to_project(expected_project)
      end

      it "removes array build setting" do
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

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes string build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings =
            configuration.build_settings.reject { |key, _| key == "HEADER_SEARCH_PATHS" }
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes hash build setting" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes hash build setting if removed hash contains the existing hash" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
          configuration.build_settings["foo"] = "baz"
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        ours_project = create_copy_of_project(base_project.path, "theirs")
        ours_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["foo"] = nil
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes value if existing is string and removed is array that contains it" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end
        base_project.save

        before_theirs_project = create_copy_of_project(base_project.path, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = ["bar"]
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes value if removed value is string and existing is array that contains it" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = ["bar"]
        end
        base_project.save

        before_theirs_project = create_copy_of_project(base_project.path, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "removes value if existing is string and removed is array that contains it among other " \
          "values" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end
        base_project.save

        before_theirs_project = create_copy_of_project(base_project.path, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar baz]
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)
        base_project.save

        expected_project = create_copy_of_project(base_project.path, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = nil
        end
        expect(base_project).to be_equivalent_to_project(expected_project)
      end

      it "changes to a single string value if removed is string and existing is array that " \
          "contains it among another value" do
        theirs_project = create_copy_of_project(base_project.path, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar baz]
        end
        base_project.save

        before_theirs_project = create_copy_of_project(base_project.path, "before_theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)
        base_project.save

        expected_project = create_copy_of_project(base_project.path, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end
        expect(base_project).to be_equivalent_to_project(expected_project)
      end

      it "changes to string value if change contains removal of existing array" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "changes to array value if change contains removal of existing string" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[baz foo]
        end

        changes_to_apply = get_diff(theirs_project, base_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(theirs_project)
      end

      it "changes to array if added value is string and existing is another string and removal is" \
          "nil for an array build setting" do
        before_theirs_project = create_copy_of_project(base_project.path, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "before_theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        expected_project = create_copy_of_project(base_project.path, "expected")
        expected_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar baz]
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        described_class.apply_change_to_project(base_project, changes_to_apply)

        expect(base_project).to be_equivalent_to_project(expected_project)
      end

      it "raises if added value is string and existing is another string and removal is nil for a " \
          "string build setting" do
        before_theirs_project = create_copy_of_project(base_project.path, "theirs")

        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "bar"
        end
        base_project.save

        theirs_project = create_copy_of_project(base_project.path, "before_theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["PRODUCT_NAME"] = "baz"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        expect {
          described_class.apply_change_to_project(base_project, changes_to_apply)
        }.to raise_error(Kintsugi::MergeError)
      end

      it "raises if trying to remove hash entry whose value changed" do
        base_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
        end

        base_project.save
        theirs_project = create_copy_of_project(base_project.path, "theirs")
        theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings = nil
        end

        base_project.save
        before_theirs_project = create_copy_of_project(base_project.path, "theirs")
        before_theirs_project.targets[0].build_configurations.each do |configuration|
          configuration.build_settings["HEADER_SEARCH_PATHS"] = "baz"
        end

        changes_to_apply = get_diff(theirs_project, before_theirs_project)

        expect {
          described_class.apply_change_to_project(base_project, changes_to_apply)
        }.to raise_error(Kintsugi::MergeError)
      end
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

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds build phase with a simple attribute value that has non nil default" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.targets[0].new_shell_script_build_phase("bar")
      theirs_project.targets[0].build_phases.last.shell_script = "Other value"

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "removes build phase" do
      base_project.targets[0].new_shell_script_build_phase("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.targets[0].shell_script_build_phases[0].remove_from_project

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

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

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end

    it "adds target dependency" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.targets[1].add_dependency(theirs_project.targets[0])

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(base_project, changes_to_apply)

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

      expect(base_project).to be_equivalent_to_project(theirs_project)
    end
  end

  it "adds known regions" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    theirs_project.root_object.known_regions += ["fr"]

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "removes known regions" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")
    theirs_project.root_object.known_regions = nil

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds attribute target changes even if target attributes don't exist" do
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.attributes["TargetAttributes"] =
      {"foo" => {"LastSwiftMigration" => "1140"}}

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

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

    expect(ours_project).to be_equivalent_to_project(theirs_project)
  end

  it "doesn't throw if existing attribute target change is same as added change" do
    base_project.root_object.attributes["TargetAttributes"] = {"foo" => "1140"}
    base_project.save

    theirs_project = create_copy_of_project(base_project.path, "theirs")
    theirs_project.root_object.attributes["TargetAttributes"]["foo"] = "1111"

    ours_project = create_copy_of_project(base_project.path, "ours")
    ours_project.root_object.attributes["TargetAttributes"]["foo"] = "1111"

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(ours_project, changes_to_apply)

    expect(ours_project).to be_equivalent_to_project(theirs_project)
  end

  it "identifies subproject added at separate times when adding a product to the subproject" do
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

  it "adds group to product group" do
    base_project_path = make_temp_directory("base", ".xcodeproj")
    base_project = Xcodeproj::Project.new(base_project_path)
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    base_project.save
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    theirs_project.root_object.product_ref_group.new_group("foo")

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  it "adds localization files to product group" do
    base_project_path = make_temp_directory("base", ".xcodeproj")
    base_project = Xcodeproj::Project.new(base_project_path)
    base_project.new_target("com.apple.product-type.library.static", "foo", :ios)

    base_project.save
    theirs_project = create_copy_of_project(base_project.path, "theirs")

    variant_group = theirs_project.root_object.product_ref_group.new_variant_group("foo.strings")
    variant_group.new_reference("Base").last_known_file_type = "text.plist.strings"

    changes_to_apply = get_diff(theirs_project, base_project)

    described_class.apply_change_to_project(base_project, changes_to_apply)

    expect(base_project).to be_equivalent_to_project(theirs_project)
  end

  describe "avoiding duplicate references to the same component" do
    it "avoids adding file reference that already exists" do
      base_project.main_group.new_reference("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.main_group.new_reference("bar")

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project.path, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding group that already exists" do
      base_project.main_group.new_group("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.main_group.new_group("bar")

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project.path, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding variant group that already exists" do
      base_project.main_group.new_variant_group("bar")
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.main_group.new_variant_group("bar")

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project.path, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding subproject that already exists" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      subproject = add_new_subproject_to_project(theirs_project, "foo", "foo")

      ours_project = create_copy_of_project(base_project.path, "ours")
      add_existing_subproject_to_project(ours_project, subproject, "foo")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(ours_project, changes_to_apply)

      expect(ours_project.root_object.project_references.count).to equal(1)
    end

    it "avoids adding build file that already exists" do
      file_reference = base_project.main_group.new_reference("bar")
      target = base_project.new_target("com.apple.product-type.library.static", "foo", :ios)
      target.frameworks_build_phase.add_file_reference(file_reference)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      file_reference = theirs_project.main_group.new_reference("bar")
      theirs_project.targets[0].frameworks_build_phase.add_file_reference(file_reference)

      changes_to_apply = get_diff(theirs_project, base_project)
      other_project = create_copy_of_project(base_project.path, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "avoids adding reference proxy that already exists" do
      framework_filename = "baz"
      subproject = add_new_subproject_to_project(base_project, "subproj", framework_filename)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")

      theirs_project.root_object.project_references[0][:product_group] <<
        create_reference_proxy_from_product_reference(theirs_project,
                                                      theirs_project.root_object.project_references[0][:project_ref],
                                                      subproject.products_group.files[-1])


      changes_to_apply = get_diff(theirs_project, base_project)

      other_project = create_copy_of_project(base_project.path, "theirs")
      described_class.apply_change_to_project(other_project, changes_to_apply)

      expect(other_project).to be_equivalent_to_project(base_project)
    end

    it "keeps array if adding string value that already exists in array" do
      base_project.new_target("com.apple.product-type.library.static", "bar", :ios)
      base_project.save

      theirs_project = create_copy_of_project(base_project.path, "theirs")
      theirs_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = "bar"
      end
      changes_to_apply = get_diff(theirs_project, base_project)

      ours_project = create_copy_of_project(base_project.path, "ours")
      ours_project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["HEADER_SEARCH_PATHS"] = %w[bar foo]
      end
      ours_project.save

      expected_project = create_copy_of_project(ours_project.path, "expected")

      described_class.apply_change_to_project(ours_project, changes_to_apply)

      expect(ours_project).to be_equivalent_to_project(expected_project)
    end
  end

  describe "allowing adding reference to the same component" do
    before do
      Kintsugi::Settings.allow_duplicates = true
    end

    after do
      Kintsugi::Settings.allow_duplicates = false
    end

    it "adds subproject that already exists" do
      theirs_project = create_copy_of_project(base_project.path, "theirs")

      subproject = add_new_subproject_to_project(theirs_project, "foo", "foo")

      ours_project = create_copy_of_project(base_project.path, "ours")
      add_existing_subproject_to_project(ours_project, subproject, "foo")

      changes_to_apply = get_diff(theirs_project, base_project)

      described_class.apply_change_to_project(ours_project, changes_to_apply)

      expect(ours_project.root_object.project_references[0][:project_ref].uuid)
        .not_to equal(ours_project.root_object.project_references[1][:project_ref].uuid)
      expect(ours_project.root_object.project_references[0][:project_ref].proxy_containers).not_to be_empty
      expect(ours_project.root_object.project_references[1][:project_ref].proxy_containers).not_to be_empty
    end
  end

  def create_copy_of_project(project_path, new_project_prefix)
    copied_project_path = make_temp_directory(new_project_prefix, ".xcodeproj")
    FileUtils.cp(File.join(project_path, "project.pbxproj"), copied_project_path)
    Xcodeproj::Project.open(copied_project_path)
  end

  def get_diff(first_project, second_project)
    diff = Xcodeproj::Differ.project_diff(first_project, second_project, :added, :removed)

    diff_without_display_name =
      diff.merge("rootObject" => diff["rootObject"].reject { |key, _| key == "displayName" })
    if diff_without_display_name == {"rootObject" => {}}
      raise "Diff contains no changes. This probably means the test doesn't check anything."
    end

    diff
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

    project.root_object.project_references[-1][:product_group] =
      project.new(Xcodeproj::Project::PBXGroup)
    project.root_object.project_references[-1][:product_group].name = "Products"
    project.root_object.project_references[-1][:product_group] <<
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

  def create_swift_package_product_dependency(project)
    product_dependency = project.new(Xcodeproj::Project::XCSwiftPackageProductDependency)
    product_dependency.product_name = "foo"
    product_dependency.package = create_remote_swift_package_reference(project)

    product_dependency
  end

  def create_remote_swift_package_reference(project)
    package_reference = project.new(Xcodeproj::Project::XCRemoteSwiftPackageReference)
    package_reference.repositoryURL = "http://foo"
    package_reference.requirement = {"foo" => "bar"}

    package_reference
  end

  def make_temp_directory(directory_prefix, directory_extension)
    directory_path = Dir.mktmpdir([directory_prefix, directory_extension])
    temporary_directories_paths << directory_path
    directory_path
  end
end
