module Gumdrop

  WEB_PAGE_EXTS= %w(.html .htm)
  JETSAM_FILES= %w(**/.DS_Store .git* .git/**/* .svn/**/* **/.sass-cache/**/* Gumdrop)

  DEFAULT_CONFIG= {
    relative_paths: true,
    relative_paths_exts: WEB_PAGE_EXTS,
    default_layout: 'site',
    layout_exts: WEB_PAGE_EXTS,
    proxy_enabled: false,
    output_dir: "./output",
    source_dir: "./source",
    data_dir: './data',
    log: STDOUT,
    log_level: :info,
    ignore: JETSAM_FILES,
    blacklist: [],
    server_timeout: 5,
    server_port: 4567,
    env: :production,
    file_change_test: :checksum
  }

  class Site
    include Util::Configurable
    include Util::Eventable
    include Util::Loggable

    config_accessor :source_dir, :output_dir, :data_dir,
                    :mode, :env, :ignore, :blacklist

    attr_reader :sitefile, :options, :root, :contents, :data, 
                :layouts, :generators, :partials, :last_run

    # hmmm... 
    attr_accessor :active_renderer, :active_builder

    # You shouldn't call this yourself! Access it via Gumdrop.site
    def initialize(sitefile, opts={})
      Gumdrop.send :set_current_site, self
      @sitefile= sitefile.expand_path
      @options= Util::HashObject.from opts
      _options_updated!
      @root= File.dirname @sitefile
      @last_run= 0
      @_preparations= []

      @contents= ContentList.new
      @layouts= SpecialContentList.new ".layout"
      @partials= SpecialContentList.new
      @generators= []
      @data= DataManager.new

      clear
    end

    def options=(opts={})
      @options.merge!(opts)
      _options_updated!
    end


    def clear()
      @contents.clear()
      @layouts.clear()
      @partials.clear()
      @generators.clear()
      @data.clear()

      # @contents= ContentList.new
      # @layouts= SpecialContentList.new ".layout"
      # @partials= SpecialContentList.new
      # @generators= []
      # @data= DataManager.new
      
      @is_scanned= false
      _reset_config!
      _load_sitefile
      self
    end

    def scan(force=false)
      if !@is_scanned or force
        clear if @is_scanned # ????
        _content_scanner
        @is_scanned= true
        generate
      end
      self
    end

    def scan_only # For testing... 
      if !@is_scanned or force
        clear if @is_scanned # ????
        _content_scanner
      end
      self
    end

    def generate
      _execute_preparations
      _execute_generators
      self
    end

    def in_blacklist?(path)
      blacklist.any? do |pattern|
        path.path_match? pattern
      end
    end

    def ignore_path?(path)
      config.ignore.any? do |pattern|
        path.path_match? pattern
      end
    end

    def source_path
      @source_path ||= source_dir.expand_path(root)
    end

    def output_path
      @output_path ||= output_dir.expand_path(root)
    end

    def data_path
      @data_path ||= data_dir.expand_path(root)
    end

    def resolve(path=nil, opts={})
      case 
        when path.is_a?(Content)
          path
        when !path.nil?
          contents.first(path) || partials.first(path)
        when opts[:page]
          contents.first opts[:page]
        when opts[:partial]
          partials.first opts[:partial]
        when opts[:layout]
          layouts.first opts[:layout]
        when opts[:generator]
          generators.first opts[:generator]
        else
          nil
      end
    end

    def prepare(&block)
      @_preparations << block
    end

    # Events stop bubbling here.
    def parent
      nil
    end

    def config_did_change
      Gumdrop.init_logging
    end

  private

    def _reset_config!
      config.clear.merge! DEFAULT_CONFIG
      config.env= @options.env.to_sym if @options.env
      config.mode= @options.mode.nil? ? :unknown : @options.mode.to_sym
    end

    def _options_updated!
      config.env= @options.env.to_sym if @options.env
      config.mode= @options.mode.nil? ? :unknown : @options.mode.to_sym
    end

    def _load_sitefile
      clear_events
      load sitefile
      data.dir= data_path
    rescue Exception => ex
      msg= "There is an error in your Gumdrop file!"
      # $stderr.puts msg
      log.error msg
      log.error ex
      raise ex
    end

    def _content_scanner
      log.info "Gumdrop v#{ Gumdrop::VERSION } - #{ Time.new }"
      log.debug "(config)"
      log.debug config
      log.debug "(options)"
      log.debug @options
      log.debug "[Scanning: #{source_path}]"
      # Report ignore list      
      ignore.each {|p| log.debug "  ignoring: #{p}" }
      # Scan Filesystem
      event_block :scan do
        scanner= Util::Scanner.new(source_path, {}, &method(:_scanner_validator)) 
        scanner.each do |path, rel|
          content= Content.new(path)
          layouts.add content and next if content.layout?
          partials.add content and next if content.partial?
          generators << Generator.new(content) and next if content.generator?
          contents.add content
          log.debug " including: #{ rel }"
        end
        contents.keys.size
      end
      @is_scanned= true
    end

    def _scanner_validator(source_path, full_path)
      return true if ignore_path? source_path
      # in_blacklist? source_path
      false
    end

    def _execute_preparations
      log.debug "[Executing Preparations]"
      dsl= Generator::DSL.new nil
      @_preparations.each do |block|
        if block.arity == 1
          block.call dsl
        else
          dsl.instance_eval &block
        end
      end
    end

    def _execute_generators
      log.debug "[Executing Generators]"
      event_block :generate do
        generators.each do |generator|
          generator.execute()
        end
      end
    end

  end

  class << self

    # This will look for a nearby Gumdrop file and load the Site
    # the first time it is called. Each time after it will just
    # return the already created Site.
    def site(opts={}, force_new=false)
      opts= opts.to_symbolized_hash
      unless @current_site.nil? or force_new
        @current_site.options= opts unless opts.empty?
        @current_site
      else
        site_file= fetch_site_file
        unless site_file.nil?
          Site.new site_file, opts
        else
          nil
        end
      end
    end

    # Listen for life-cycle events in your Gumdrop file like this:
    #
    #   Gumdrop.on :start do |event|
    #     puts "Here we go!"
    #   end
    #
    # Complete list of events fired by Gumdrop:
    #
    #   :start
    #   :before_scan
    #   :scan
    #   :after_scan
    #   :before_generate
    #   :generate
    #   :after_generate
    #   :before_generate_item
    #   :generate_item
    #   :after_generate_item
    #   :before_build
    #   :build
    #   :after_build
    #   :before_checksum
    #   :checksum
    #   :after_checksum
    #   :before_render
    #   :render
    #   :after_render
    #   :before_render_item
    #   :render_item
    #   :after_render_item
    #   :before_write
    #   :write
    #   :after_write
    #   :before_copy_file
    #   :copy_file
    #   :after_copy_file
    #   :before_write_file
    #   :write_file
    #   :after_write_file
    #   :end
    #
    # In the block parem `event` you will have access to :site, the 
    # current executing site instance, and :payload, where applicable.
    #
    # :render_item is a special event because you can add/override the
    # compiled output by modifying `event.data.return_value`
    #
    def on(event_type, options={}, &block)
      site.on event_type, options, &block
    end

    # Yield a configuration object. You can update Gumdrop behavior
    # as well as add your own config information.
    def configure(&block)
      site.configure &block
    end

    def prepare(&block)
      site.prepare &block
    end

    # Short cut to the current Site config object.
    def config
      site.config
    end

    # The env Gumdrop is run in -- You can set this in the config
    # or, better, via command line: `gumdrop build -e test`
    def env
      site.env
    end
    
    # Mostly for internal use, but you can update/change it in the
    # configure block.
    def mode
      site.mode
    end

    # Returns true if this, or a parent, folder has a Gumdrop file.
    def in_site_folder?(filename="Gumdrop")
      !fetch_site_file(filename).nil?
    end

    # Specified paths will be added to the ignore list, preventing
    # matching files from appearing in the source tree
    def ignore(*paths)
      paths.each do |path|
        if path.is_a? Array
          config.ignore.concat path
        else
          config.ignore << path
        end
      end      
    end

    # Specified paths will not be renderd to output (matching against
    # the source tree).
    def blacklist(*paths)
      paths.each do |path|
        if path.is_a? Array
          config.blacklist.concat path
        else
          config.blacklist << path
        end
      end      
    end

  protected

    # Walks up the filesystem, starting from Dir.pwd, looking for
    # a Gumdrop file. Returns nil if not found.
    def fetch_site_file(filename="Gumdrop")
      here= Dir.pwd
      found= File.file?  here / filename
      # TODO: Should be smarter -- This is a hack for Windows support "C:\"
      while !found and File.directory?(here) and File.dirname(here).length > 3
        here= File.expand_path here /'..'
        found= File.file?  here / filename
      end
      if found
        File.expand_path here / filename
      else
        nil
      end
    end

    def set_current_site(site)
      @current_site= site
    end

  end

end

