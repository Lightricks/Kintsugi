# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "git"
require "json"
require "rspec"
require "tempfile"
require "tmpdir"

require "kintsugi"

shared_examples "tests" do |git_command, project_name|
  let(:temporary_directories_paths) { [] }
  let(:git_directory_path) { make_temp_directory }
  let(:git) { Git.init(git_directory_path) }

  before do
    git.config("user.email", "you@example.com")
    git.config("user.name", "Your Name")
  end

  after do
    temporary_directories_paths.each do |directory_path|
      FileUtils.remove_entry(directory_path)
    end
  end

  context "running 'git #{git_command}' with project name '#{project_name}'" do
    it "resolves conflicts with root command" do
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=Unset")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      project.new_target("com.apple.product-type.library.static", "foo", :ios)
      project.save

      git.add(all: true)
      git.commit("Add target foo")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "bar", :ios)
      project.save
      git.add(all: true)
      git.commit("Add target bar")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`
      Kintsugi.run([File.join(project.path, "project.pbxproj")])

      project = Xcodeproj::Project.open(project.path)
      expect(project.targets.map(&:display_name)).to contain_exactly("foo", "bar")
    end

    it "resolves conflicts automatically with driver" do
      git.config("merge.kintsugi.name", "Kintsugi driver")
      git.config("merge.kintsugi.driver", "#{__dir__}/../bin/kintsugi driver %O %A %B %P")
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=kintsugi")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      project.new_target("com.apple.product-type.library.static", "foo", :ios)
      project.save

      git.add(all: true)
      git.commit("Add target foo")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "bar", :ios)
      project.save
      git.add(all: true)
      git.commit("Add target bar")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`

      project = Xcodeproj::Project.open(project.path)
      expect(project.targets.map(&:display_name)).to contain_exactly("foo", "bar")
    end

    it "keeps conflicts if failed to resolve conflicts" do
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=Unset")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))
      project.new_target("com.apple.product-type.library.static", "foo", :ios)
      project.save

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["PRODUCT_NAME"] = "bar"
      end
      project.save
      git.add(all: true)
      git.commit("Change target product name to bar")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.targets[0].build_configurations.each do |configuration|
        configuration.build_settings["PRODUCT_NAME"] = "baz"
      end
      project.save
      git.add(all: true)
      git.commit("Change target product name to baz")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`

      arguments = [File.join(project.path, "project.pbxproj"), "--interactive-resolution", "false"]
      expect {
        Kintsugi.run(arguments)
      }.to raise_error(Kintsugi::MergeError)
      expect(`git -C #{git_directory_path} diff --name-only --diff-filter=U`.chomp)
        .to eq("#{project_name}/project.pbxproj")
    end

    it "resolves conflicts when adding a file system synchronized root group" do
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=Unset")

      project = create_new_project_at_path(File.join(git_directory_path, project_name))

      git.add(File.join(git_directory_path, ".gitattributes"))
      git.add(project.path)
      git.commit("Initial project")

      # A buildable folder, as created by Xcode 16: a `PBXFileSystemSynchronizedRootGroup` that
      # lives in the main group and is referenced by the target. Before this feature, merging any
      # conflict on such a project failed with "Trying to add unsupported component type
      # PBXFileSystemSynchronizedRootGroup".
      target = project.new_target("com.apple.product-type.library.static", "foo", :ios)
      group = project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      group.source_tree = "<group>"
      group.path = "SyncedSources"
      project.main_group.children << group
      target.file_system_synchronized_groups << group
      project.save

      git.add(all: true)
      git.commit("Add target foo with a buildable folder")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "bar", :ios)
      project.save
      git.add(all: true)
      git.commit("Add target bar")

      `git -C #{git_directory_path} #{git_command} #{first_commit_hash} &> /dev/null`
      Kintsugi.run([File.join(project.path, "project.pbxproj")])

      project = Xcodeproj::Project.open(project.path)
      synchronized_groups = project.objects.select do |object|
        object.isa == "PBXFileSystemSynchronizedRootGroup"
      end
      expect(project.targets.map(&:display_name)).to contain_exactly("foo", "bar")
      expect(synchronized_groups.count).to eq(1)
      expect(project.targets.find { |native_target| native_target.display_name == "foo" }
                    .file_system_synchronized_groups.first).to equal(synchronized_groups.first)
    end
  end

  def make_temp_directory
    directory_path = Dir.mktmpdir
    temporary_directories_paths << directory_path
    directory_path
  end
end

def create_new_project_at_path(path)
  project = Xcodeproj::Project.new(path)
  project.save
  project
end

def find_exception_set_hash(plist)
  plist["objects"].values.find do |object|
    object["isa"] == "PBXFileSystemSynchronizedBuildFileExceptionSet"
  end
end

def write_exception_set_asset_tags(project_path, asset_tags)
  pbxproj_path = File.join(project_path, "project.pbxproj")
  plist = Xcodeproj::Plist.read_from_path(pbxproj_path)
  find_exception_set_hash(plist)["assetTagsByRelativePath"] = asset_tags
  File.open(pbxproj_path, "w") do |file|
    Nanaimo::Writer::PBXProjWriter
      .new(Nanaimo::Plist.new(plist, :ascii), pretty: true, output: file, strict: false).write
  end
end

def read_exception_set_asset_tags(project_path)
  plist = Xcodeproj::Plist.read_from_path(File.join(project_path, "project.pbxproj"))
  exception_set = find_exception_set_hash(plist)
  exception_set && exception_set["assetTagsByRelativePath"]
end

describe Kintsugi, :kintsugi do
  %w[rebase cherry-pick merge].each do |git_command|
    ["foo.xcodeproj", "foo with space.xcodeproj"].each do |project_name|
      it_behaves_like("tests", git_command, project_name)
    end
  end

  context "when merging a project with on-demand resource asset tags" do
    let(:temporary_directories_paths) { [] }
    let(:git_directory_path) { Dir.mktmpdir.tap { |path| temporary_directories_paths << path } }
    let(:git) { Git.init(git_directory_path) }

    before do
      git.config("user.email", "you@example.com")
      git.config("user.name", "Your Name")
    end

    after do
      temporary_directories_paths.each do |directory_path|
        FileUtils.remove_entry(directory_path)
      end
    end

    it "keeps 'assetTagsByRelativePath' of an exception set when resolving with driver" do
      git.config("merge.kintsugi.name", "Kintsugi driver")
      git.config("merge.kintsugi.driver", "#{__dir__}/../bin/kintsugi driver %O %A %B %P")
      File.write(File.join(git_directory_path, ".gitattributes"), "*.pbxproj merge=kintsugi")

      asset_tags = {"OnDemandAssets/Level1.imageset" => ["level1"]}

      project = create_new_project_at_path(File.join(git_directory_path, "foo.xcodeproj"))
      target = project.new_target("com.apple.product-type.library.static", "foo", :ios)
      group = project.new(Xcodeproj::Project::PBXFileSystemSynchronizedRootGroup)
      group.source_tree = "<group>"
      group.path = "SyncedSources"
      exception_set =
        project.new(Xcodeproj::Project::PBXFileSystemSynchronizedBuildFileExceptionSet)
      exception_set.target = target
      exception_set.membership_exceptions = ["Excluded.swift"]
      group.exceptions << exception_set
      project.main_group.children << group
      target.file_system_synchronized_groups << group
      project.save
      # `assetTagsByRelativePath` is written to the file directly because not all xcodeproj
      # versions in the supported range model this attribute, and those that don't drop it when
      # a project is saved, which is exactly what this test guards against.
      write_exception_set_asset_tags(project.path, asset_tags)

      git.add(all: true)
      git.commit("Initial project")

      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "bar", :ios)
      project.save
      write_exception_set_asset_tags(project.path, asset_tags)
      git.add(all: true)
      git.commit("Add target bar")
      first_commit_hash = git.revparse("HEAD")

      git.checkout("HEAD^")
      project = Xcodeproj::Project.open(project.path)
      project.new_target("com.apple.product-type.library.static", "baz", :ios)
      project.save
      write_exception_set_asset_tags(project.path, asset_tags)
      git.add(all: true)
      git.commit("Add target baz")

      `git -C #{git_directory_path} merge #{first_commit_hash} &> /dev/null`

      project = Xcodeproj::Project.open(project.path)
      expect(project.targets.map(&:display_name)).to contain_exactly("foo", "bar", "baz")
      expect(read_exception_set_asset_tags(project.path)).to eq(asset_tags)
    end
  end
end
