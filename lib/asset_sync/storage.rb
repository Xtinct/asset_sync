require "fog/core"

require "asset_sync/multi_mime"

module AssetSync
  class Storage
    REGEXP_FINGERPRINTED_FILES = /^(.*)\/([^-]+)-[^\.]+\.([^\.]+)$/
    REGEXP_ASSETS_TO_CACHE_CONTROL = /-[0-9a-fA-F]{32,}$/

    class BucketNotFound < StandardError;
    end

    attr_accessor :config

    def initialize(cfg)
      @config = cfg
    end

    def connection
      @connection ||= Fog::Storage.new(self.config.fog_options)
    end

    def buckets
      return @_buckets if @_buckets
      @_buckets = []
      self.config.remote_asset_paths.each do |prefix|
        @_buckets << connection.directories.get(self.config.fog_directory, prefix: prefix)
      end
      @_buckets
    end

    def bucket
      # fixes: https://github.com/rumblelabs/asset_sync/issues/18
      @bucket ||= connection.directories.get(self.config.fog_directory, :prefix => self.config.assets_prefix)
    end

    def log(msg)
      AssetSync.log(msg)
    end

    def keep_existing_remote_files?
      self.config.existing_remote_files?
    end

    def path
      self.config.public_path
    end

    def ignored_files
      expand_file_names(self.config.ignored_files)
    end

    def get_manifest_path
      return [] unless self.config.include_manifest

      if ActionView::Base.respond_to?(:assets_manifest)
        manifest = Sprockets::Manifest.new(ActionView::Base.assets_manifest.environment, ActionView::Base.assets_manifest.dir)
        manifest_path = manifest.filename
      else
        manifest_path = self.config.manifest_path
      end
      [manifest_path.sub(/^#{path}\//, "")] # full path to relative path
    end

    def local_files
      @local_files ||=
        (get_local_files + config.additional_local_file_paths).uniq
    end

    def always_upload_files
      expand_file_names(self.config.always_upload) + get_manifest_path
    end

    def files_with_custom_headers
      self.config.custom_headers.inject({}) { |h,(k, v)| h[File.join(self.config.assets_prefix, k)] = v; h; }
    end

    def files_to_invalidate
      self.config.invalidate.map { |filename| File.join("/", self.config.assets_prefix, filename) }
    end

    # @api
    #   To get a list of asset files indicated in a manifest file.
    #   It makes sense if a user sets `config.manifest` is true.
    def get_asset_files_from_manifest
      if self.config.manifest
        if ActionView::Base.respond_to?(:assets_manifest)
          log "Using: Rails 4.0 manifest access"
          manifest = Sprockets::Manifest.new(ActionView::Base.assets_manifest.environment, ActionView::Base.assets_manifest.dir)
          return manifest.assets.values.map { |f| File.join(self.config.assets_prefix, f) }
        elsif File.exist?(self.config.manifest_path)
          log "Using: Manifest #{self.config.manifest_path}"
          yml = YAML.load(IO.read(self.config.manifest_path))

          return yml.map do |original, compiled|
            # Upload font originals and compiled
            if original =~ /^.+(eot|svg|ttf|woff)$/
              [original, compiled]
            else
              compiled
            end
          end.flatten.map { |f| File.join(self.config.assets_prefix, f) }.uniq!
        else
          log "Warning: Manifest could not be found"
        end
      end
    end

    def get_local_files
      if from_manifest = get_asset_files_from_manifest
        return from_manifest
      end

      log "Using: Directory Search of #{path}/#{self.config.assets_prefix}"
      Dir.chdir(path) do
        to_load = self.config.assets_prefix.present? ? "#{self.config.assets_prefix}/**/**" : '**/**'
        Dir[to_load]
      end
    end

    def get_remote_files
      raise BucketNotFound.new("#{self.config.fog_provider} Bucket: #{self.config.fog_directory} not found.") unless bucket
      # fixes: https://github.com/rumblelabs/asset_sync/issues/16
      #        (work-around for https://github.com/fog/fog/issues/596)
      files = []

      buckets.each do |bucket|
        bucket.files.each { |f| files << f.key }
      end
      return files
    end

    def delete_file(f, remote_files_to_delete)
      if remote_files_to_delete.include?(f.key)
        log "Deleting: #{f.key}"
        f.destroy
      end
    end

    def delete_extra_remote_files
      log "Fetching files to flag for delete"
      remote_files = get_remote_files
      # fixes: https://github.com/rumblelabs/asset_sync/issues/19
      from_remote_files_to_delete = remote_files - local_files - ignored_files - always_upload_files

      log "Flagging #{from_remote_files_to_delete.size} file(s) for deletion"
      # Delete unneeded remote files
      bucket.files.each do |f|
        delete_file(f, from_remote_files_to_delete)
      end
    end

    def upload_file(f)
      # TODO output files in debug logs as asset filename only.
      one_year = 31557600
      ext = File.extname(f)[1..-1]
      mime = MultiMime.lookup(ext)
      gzip_file_handle = nil
      file_handle = File.open("#{path}/#{f}")
      file = {
        :key => f,
        :body => file_handle,
        :content_type => mime
      }

      # region fog_public

      if config.fog_public.use_explicit_value?
        file[:public] = config.fog_public.to_bool
      end

      # endregion fog_public

      uncompressed_filename = f.sub(/\.gz\z/, '')
      basename = File.basename(uncompressed_filename, File.extname(uncompressed_filename))

      assets_to_cache_control = Regexp.union([REGEXP_ASSETS_TO_CACHE_CONTROL] | config.cache_asset_regexps).source
      if basename.match(Regexp.new(assets_to_cache_control)).present?
        file.merge!({
          :cache_control => "public, max-age=#{one_year}",
          :expires => CGI.rfc1123_date(Time.now + one_year)
        })
      end

      # overwrite headers if applicable, you probably shouldn't specific key/body, but cache-control headers etc.

      if files_with_custom_headers.has_key? f
        file.merge! files_with_custom_headers[f]
        log "Overwriting #{f} with custom headers #{files_with_custom_headers[f].to_s}"
      elsif key = self.config.custom_headers.keys.detect {|k| f.match(Regexp.new(k))}
        headers = {}
        self.config.custom_headers[key].each do |k, value|
          headers[k.to_sym] = value
        end
        file.merge! headers
        log "Overwriting matching file #{f} with custom headers #{headers.to_s}"
      end


      gzipped = "#{path}/#{f}.gz"
      ignore = false

      if config.gzip? && File.extname(f) == ".gz"
        # Don't bother uploading gzipped assets if we are in gzip_compression mode
        # as we will overwrite file.css with file.css.gz if it exists.
        log "Ignoring: #{f}"
        ignore = true
      elsif config.gzip? && File.exist?(gzipped)
        original_size = File.size("#{path}/#{f}")
        gzipped_size = File.size(gzipped)

        if gzipped_size < original_size
          percentage = ((gzipped_size.to_f/original_size.to_f)*100).round(2)
          gzip_file_handle = File.open(gzipped)
          file.merge!({
                        :key => f,
                        :body => gzip_file_handle,
                        :content_encoding => 'gzip'
                      })
          log "Uploading: #{gzipped} in place of #{f} saving #{percentage}%"
        else
          percentage = ((original_size.to_f/gzipped_size.to_f)*100).round(2)
          log "Uploading: #{f} instead of #{gzipped} (compression increases this file by #{percentage}%)"
        end
      else
        if !config.gzip? && File.extname(f) == ".gz"
          # set content encoding for gzipped files this allows cloudfront to properly handle requests with Accept-Encoding
          # http://docs.amazonwebservices.com/AmazonCloudFront/latest/DeveloperGuide/ServingCompressedFiles.html
          uncompressed_filename = f[0..-4]
          ext = File.extname(uncompressed_filename)[1..-1]
          mime = MultiMime.lookup(ext)
          file.merge!({
            :content_type     => mime,
            :content_encoding => 'gzip'
          })
        end
        log "Uploading: #{f}"
      end

      if config.aws? && config.aws_rrs?
        file.merge!({
          :storage_class => 'REDUCED_REDUNDANCY'
        })
      end

      if config.azure_rm?
        # converts content_type from MIME::Type to String.
        # because Azure::Storage (called from Fog::AzureRM) expects content_type as a String like "application/json; charset=utf-8"
        file[:content_type] = file[:content_type].content_type if file[:content_type].is_a?(::MIME::Type)
      end

      bucket.files.create( file ) unless ignore
      file_handle.close
      gzip_file_handle.close if gzip_file_handle
    end

    def upload_files
      # get a fresh list of remote files
      remote_files = ignore_existing_remote_files? ? [] : get_remote_files
      # fixes: https://github.com/rumblelabs/asset_sync/issues/19
      local_files_to_upload = local_files - ignored_files - remote_files + always_upload_files
      local_files_to_upload = (local_files_to_upload + get_non_fingerprinted(local_files_to_upload)).uniq

      # Upload new files
      local_files_to_upload.each do |f|
        next unless File.file? "#{path}/#{f}" # Only files.
        upload_file f
      end

      if self.config.cdn_distribution_id && files_to_invalidate.any?
        log "Invalidating Files"
        cdn ||= Fog::CDN.new(self.config.fog_options.except(:region))
        data = cdn.post_invalidation(self.config.cdn_distribution_id, files_to_invalidate)
        log "Invalidation id: #{data.body["Id"]}"
      end
    end

    def sync
      # fixes: https://github.com/rumblelabs/asset_sync/issues/19
      log "AssetSync: Syncing."
      upload_files
      delete_extra_remote_files unless keep_existing_remote_files?
      log "AssetSync: Done."
    end

    private

    def ignore_existing_remote_files?
      self.config.existing_remote_files == 'ignore'
    end

    def get_non_fingerprinted(files)
      files.map do |file|
        match_data = file.match(REGEXP_FINGERPRINTED_FILES)
        match_data && "#{match_data[1]}/#{match_data[2]}.#{match_data[3]}"
      end.compact
    end

    def expand_file_names(names)
      files = []
      Array(names).each do |name|
        case name
          when Regexp
            files += self.local_files.select do |file|
              file =~ name
            end
          when String
            files += self.local_files.select do |file|
              file.split('/').last == name
            end
          else
            log "Error: please define file names as string or regular expression. #{name} (#{name.class}) ignored."
        end
      end
      files.uniq
    end

  end
end
