
# Maybe use Gserver?

require 'sinatra/base'

module Gumdrop

  STATIC_ASSETS= %w(.jpg .jpe .jpeg .gif .ico .png .swf)

  class RenderPool
  end

  class Server < Sinatra::Base
    include Util::Loggable

    site= Gumdrop.site
    scan_count= 0
    gc_after= 3

    unless site.nil?
      site.scan true
      scan_count += 1
      last_scan= Time.now.to_i

      set :port, site.config.server_port if site.config.server_port
      
      if site.config.proxy_enabled
        require 'gumdrop/server/proxy_handler'
        get     '/-proxy/*' do handle_proxy(params, env) end
        post    '/-proxy/*' do handle_proxy(params, env) end
        put     '/-proxy/*' do handle_proxy(params, env) end
        delete  '/-proxy/*' do handle_proxy(params, env) end
        patch   '/-proxy/*' do handle_proxy(params, env) end
        options '/-proxy/*' do handle_proxy(params, env) end
        log.info 'Enabled proxy at /-proxy/*'
      end

      get '/*' do
        # log.info "- - - - - - - - - - - - - - - - - - - - - - - - - - - - -"

        file_path= get_content_path params[:splat].join('/'), site
        log.info "\n\n[#{$$}] GET /#{params[:splat].join('/')} -> #{file_path}"
        
        unless static_asset file_path
          since_last_build= Time.now.to_i - last_scan
          # site.report "!>!>>>>> since_last_build: #{since_last_build}"
          if since_last_build > site.config.server_timeout
            log.info "[#{$$}] Rebuilding from Source (#{since_last_build} > #{site.config.server_timeout}) #{scan_count % gc_after}"
            last_scan= Time.now.to_i
            site.scan true
            scan_count += 1
            log.info "[#{$$}] Finished re-scan - #{ Time.now.to_i - last_scan }s"
            if scan_count % gc_after == 0
              log.info "<* Initiating Garbage Collection *>"
              GC.start
            end
          end
        end
        
        if site.contents.has_key? file_path
          content= site.contents[file_path]
          content_type :css if content.ext == '.css' # Meh?
          content_type :js if content.ext == '.js' # Meh?
          content_type :xml if content.ext == '.xml' # Meh?
          unless content.binary?
            log.info "[#{$$}]  *Dynamic: #{file_path} (#{content.ext})"
            begin
              renderer= Renderer.new
              content= renderer.draw content  
            rescue => ex
              log.error "ERROR!"
              log.error ex
              $stderr.puts "\n\n --------- \n Error! (#{content.uri}) #{ex}\n --------- \n\n"
              raise ex
            end
            content
          else
            log.info "[#{$$}]  *Static: #{file_path} (binary)"
            send_file site.source_path / file_path
          end
        
        elsif File.exists? site.output_path / file_path
            log.info "[#{$$}]  *Static (from OUTPUT): #{file_path}"
            send_file site.output_path / file_path
        
        else
          log.warn "[#{$$}]  *Missing: #{file_path}"
          "#{file_path} Not Found"
        end
      end      

      def get_content_path(file_path, site)
        keys= [
          file_path,
          "#{file_path}.html",
          "#{file_path}/index.html"
        ]
        if file_path == ""
          "index.html"
        else
          keys.detect {|k| site.contents.has_key?(k) } or file_path
        end
      end

      def handle_proxy(params, env)
        proxy_to= params[:splat][0]
        proxy_parts= proxy_to.split('/')
        host= proxy_parts.shift
        path_info= "/#{proxy_parts.join('/')}"
        #puts "HOST: #{host}  PATH_INFO: #{path_info}"
        opts={ :to=>host, :path_info=>path_info  }
        Gumdrop.handle_proxy opts, proxy_to, env
      end
      
      def static_asset(file_path)
        return false if file_path.nil? or File.extname(file_path).nil?
        STATIC_ASSETS.include? File.extname(file_path).to_s
      end
      
      run!
    else
      puts "Not in a valid Gumdrop site directory."
    end
  end
end