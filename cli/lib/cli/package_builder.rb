require "blobstore_client"

module Bosh::Cli

  class PackageBuilder

    attr_reader :name, :globs, :version, :dependencies, :tarball_path, :checksum

    # We have two ways of getting/storing a package:
    # development versions of packages, kept in release directory
    # final versions of packages, kept in blobstore
    # development packages and their metadata should always be gitignored
    # final build tarballs should be ignored as well
    # final builds metadata should be checked in

    def initialize(spec, release_dir, final, blobstore, sources_dir = nil)
      spec = YAML.load_file(spec) if spec.is_a?(String) && File.file?(spec)
      
      @name         = spec["name"]
      @globs        = spec["files"]
      @dependencies = spec["dependencies"].is_a?(Array) ? spec["dependencies"] : []      
      @release_dir  = release_dir
      @sources_dir  = sources_dir || File.join(@release_dir, "src")
      @final        = final
      @blobstore    = blobstore

      if @name.blank?
        raise InvalidPackage, "Package name is missing"
      end

      unless @name.bosh_valid_id?
        raise InvalidPackage, "Package name should be a valid Bosh identifier"
      end

      unless @globs.is_a?(Array) && @globs.size > 0
        raise InvalidPackage, "Package '#{@name}' doesn't include any files"
      end

      FileUtils.mkdir_p(metadata_dir)      

      FileUtils.touch(dev_builds_index_file)
      FileUtils.touch(final_builds_index_file)

      FileUtils.mkdir_p(dev_builds_dir)
      FileUtils.mkdir_p(final_builds_dir)
      
      @dev_packages   = PackagesIndex.new(dev_builds_index_file, dev_builds_dir)
      @final_packages = PackagesIndex.new(final_builds_index_file, final_builds_dir)
    end

    def build
      use_final_version || use_dev_version || generate_tarball
      upload_tarball(@tarball_path) if final_build?      
    end

    def final_build?
      @final
    end

    def checksum
      if @tarball_path && File.exists?(@tarball_path)
        Digest::SHA1.hexdigest(File.read(@tarball_path))
      else
        raise RuntimeError, "cannot read checksum for not yet generated package"
      end
    end

    def use_final_version
      say "Looking for final version of `#{name}'"
      package_attrs = @final_packages[fingerprint]

      if package_attrs.nil?
        say "Final version of `#{name}' not found"
        return nil
      end

      blobstore_id = package_attrs["blobstore_id"]
      version      = package_attrs["version"]

      if @final_packages.version_exists?(version)
        say "Found final version `#{name}' (#{version}) in local cache"
        @tarball_path = @final_packages.filename(version)
      else
        say "Fetching `#{name}' (final version #{version}) from blobstore (#{blobstore_id})"
        payload = @blobstore.get(blobstore_id)        
        @tarball_path = @final_packages.add_package(fingerprint, package_attrs, payload)        
      end

      @version = version
      true

    rescue Bosh::Blobstore::NotFound => e
      raise InvalidPackage, "Final version of `#{name}' not found in blobstore"
    rescue Bosh::Blobstore::BlobstoreError => e
      raise InvalidPackage, "Blobstore error: #{e}"
    end

    def use_dev_version
      say "Looking for dev version of `#{name}'"
      package_attrs = @dev_packages[fingerprint]

      if package_attrs.nil?
        say "Dev version of `#{name}' not found"
        return nil
      end

      version = package_attrs["version"]
      
      if @dev_packages.version_exists?(version)
        say "Found dev version `#{name}' (#{version})"
        @tarball_path = @dev_packages.filename(version)
        @version      = version
        true        
      else
        say "Tarball for `#{name}' (dev version `#{version}') not found"        
        nil
      end
    end

    def generate_tarball
      package_attrs = @dev_packages[fingerprint]      

      version  = \
      if package_attrs.nil?
        @dev_packages.next_version
      else
        package_attrs["version"]
      end

      tmp_file = Tempfile.new(name)

      say "Generating `#{name}' (dev version #{version})"

      copy_files

      in_build_dir do
        tar_out = `tar -czf #{tmp_file.path} . 2>&1`
        raise InvalidPackage, "Cannot create package tarball: #{tar_out}" unless $?.exitstatus == 0
      end

      payload = tmp_file.read
      
      package_attrs = {
        "version" => version,
        "sha1"    => Digest::SHA1.hexdigest(payload)
      }

      @dev_packages.add_package(fingerprint, package_attrs, payload)

      @tarball_path = @dev_packages.filename(version)
      @version      = version      

      say "Generated `#{name}' (dev version #{version}): `#{@tarball_path}'"
      true
    end

    def upload_tarball(path)
      package_attrs = @final_packages[fingerprint]

      if !package_attrs.nil?
        version = package_attrs["version"]
        say "`#{name}' (final version #{version}) already uploaded"
        return
      end
      
      version = @final_packages.next_version
      payload = File.read(path)

      say "Uploading `#{path}' as `#{name}' (final version #{version})"

      blobstore_id = @blobstore.create(payload)
      
      package_attrs = {
        "blobstore_id" => blobstore_id,
        "sha1"         => Digest::SHA1.hexdigest(payload),
        "version"      => version
      }

      say "`#{name}' (final version #{version}) uploaded, blobstore id #{blobstore_id}"
      @final_packages.add_package(fingerprint, package_attrs, payload)
      @tarball_path = @final_packages.filename(version)
      @version      = version
      true
    rescue Bosh::Blobstore::BlobstoreError => e
      raise InvalidPackage, "Blobstore error: #{e}"
    end

    def reload # Mostly for tests
      @fingerprint    = nil
      @resolved_globs = nil
      self
    end

    def fingerprint
      @fingerprint ||= make_fingerprint
    end

    # lib/sphinx-0.9.tar.gz => lib/sphinx-0.9.tar.gz
    # but "cloudcontroller/lib/cloud.rb => lib/cloud.rb"
    def strip_package_name(filename)
      pos = filename.index(File::SEPARATOR)
      if pos && filename[0..pos-1] == @name
        filename[pos+1..-1]
      else
        filename
      end
    end

    def resolved_globs
      @resolved_globs ||= resolve_globs
    end
    alias_method :files, :resolved_globs

    def build_dir
      @build_dir ||= Dir.mktmpdir
    end

    def package_dir
      File.join(@release_dir, "packages", @name)
    end

    def metadata_dir
      File.join(package_dir, "data")
    end

    def dev_builds_index_file
      File.join(package_dir, "dev_builds.yml")
    end

    def dev_builds_dir
      File.join(package_dir, "dev_builds")
    end

    def final_builds_index_file
      File.join(package_dir, "final_builds.yml")
    end    

    def final_builds_dir
      File.join(package_dir, "final_builds")
    end

    def copy_files
      copied = 0
      in_sources_dir do
        resolved_globs.each do |filename|
          destination = File.join(build_dir, strip_package_name(filename))

          if File.directory?(filename)
            FileUtils.mkdir_p(destination)
          else
            FileUtils.mkdir_p(File.dirname(destination))
            FileUtils.cp(filename, destination)
            copied += 1
          end
        end
      end

      in_metadata_dir do
        Dir["*"].each do |filename|
          destination = File.join(build_dir, filename)
          if File.exists?(destination)
            raise InvalidPackage, "Package '#{name}' has '#{filename}' file that conflicts with one of its metadata files"
          end
          FileUtils.cp(filename, destination)
          copied += 1
        end
      end

      copied
    end

    private

    def make_fingerprint
      contents = ""
      # First, source files (+ permissions)
      in_sources_dir do
        contents << resolved_globs.sort.map { |file|
          "%s%s%s" % [ file, File.directory?(file) ? nil : File.read(file), File.stat(file).mode.to_s(8) ]
        }.join("")
      end
      # Second, metadata files (packaging, migrations, whatsoever)
      in_metadata_dir do
        contents << Dir["*"].sort.map { |file|
          "%s%s" % [ file, File.directory?(file) ? nil : File.read(file) ]
        }.join("")
      end

      Digest::SHA1.hexdigest(contents)    
    end

    def resolve_globs
      in_sources_dir do
        @globs.map { |glob| Dir[glob] }.flatten.sort
      end
    end    

    def in_sources_dir(&block)
      Dir.chdir(@sources_dir) { yield }
    end

    def in_build_dir(&block)
      Dir.chdir(build_dir) { yield }
    end

    def in_metadata_dir(&block)
      Dir.chdir(metadata_dir) { yield }
    end

  end

  # Helper class to avoid too much boilerplate in PackageBuilder
  class PackagesIndex
    def initialize(index_file, storage_dir)
      @index_file  = File.expand_path(index_file)
      @storage_dir = File.expand_path(storage_dir)

      unless File.file?(index_file) && File.readable?(index_file)
        raise InvalidPackage, "Cannot read package index file: #{index_file}"
      end

      unless File.directory?(storage_dir)
        raise InvalidPackage, "Cannot read package storage directory: #{storage_dir}"
      end

      @data = YAML.load_file(@index_file)
      @data = { } unless @data.is_a?(Hash)
    end

    def [](fingerprint)
      @data[fingerprint]
    end

    def next_version
      @data.values.map{ |v| v["version"].to_i }.max.to_i + 1
    end

    def version_exists?(version)
      File.exists?(filename(version))
    end

    def add_package(fingerprint, package_attrs, payload)
      version = package_attrs["version"]
      
      if version.blank?
        raise InvalidPackage, "Cannot save package without knowing its version"
      end

      File.open(filename(version), "w") do |f|
        f.write(payload)
      end

      @data[fingerprint] = package_attrs

      File.open(@index_file, "w") do |f|
        f.write(YAML.dump(@data))
      end

      File.expand_path(filename(version))
    end

    def filename(version)
      File.join(@storage_dir, "#{version}.tgz")      
    end
    
  end

end
