class Router

  VERSION = 0.99
  class << self
    attr_reader   :log, :droplets, :registered_droplets, :unregistered_droplets, :going_down_droplets
    attr_reader   :proxies, :registered_proxy, :unregistered_proxy
    attr_accessor :timestamp, :shutting_down

    alias :shutting_down? :shutting_down

    def version
      VERSION
    end

    def config(config)
      @droplets = {}
      @registered_droplets= {}
      @unregistered_droplets = {}
      @graveyard = {}
      @proxies = {}
      @registered_proxy = {}
      @unregistered_proxy = {}
      @going_down_droplets = {}
      VCAP::Logging.setup_from_config(config['logging'] || {})
      @log = VCAP::Logging.logger('router')
      @use_lb = config['use_lb']
      @retry = false
      @haproxy_file = config['haproxy_file']
      @haproxy_config = config['haproxy_config']
    end

    def setup_listeners
      NATS.subscribe('router.register') { |msg|
        msg_hash = Yajl::Parser.parse(msg, :symbolize_keys => true)
        return unless uris = msg_hash[:uris]
        uris.each { |uri| 
          register_droplet(uri, msg_hash[:host], msg_hash[:port], msg_hash[:tags]) 
        }
        # register debug urls
        unless msg_hash[:debug_url_prefix].nil? then
          uris.each { |uri| 
            debug_url = [msg_hash[:debug_url_prefix], uri].join('.')
            register_proxy(debug_url, msg_hash[:host], msg_hash[:debug_port], msg_hash[:instance_id], 'debug') 
          }  
        end
      }
      NATS.subscribe('router.unregister') { |msg|
        msg_hash = Yajl::Parser.parse(msg, :symbolize_keys => true)
        return unless uris = msg_hash[:uris]
        uris.each { |uri| 
          unregister_droplet(uri, msg_hash[:host], msg_hash[:port], msg_hash[:instance_id], msg_hash[:app]) 
        }

        unless msg_hash[:debug_url_prefix].nil? then
          uris.each { |uri| 
            debug_url = [msg_hash[:debug_url_prefix], uri].join('.')
            unregister_proxy(debug_url, msg_hash[:host], msg_hash[:debug_port]) 
          }  
        end
      }
    end 

    def setup_sweepers
      EM.add_periodic_timer(CHECK_SWEEPER) {
        check_registered_urls
      }
    end

    # setup varnish updater timer
    def setup_updater
      EM.add_periodic_timer(VARNISH_RELOAD) {
        update_droplet
      }
      EM.add_periodic_timer(HAPROXY_RELOAD) {
        update_proxy
      }
      EM.add_periodic_timer(GRAVEYARD_CLEAN) {
        search_graveyard
      }
    end

    def get_old_connections
      begin
        connection_list = `varnishadm -T 127.0.0.1:2000 vcl.list`
        connection_list.split("\n")
        return if connection_list.empty?

        entries = connection_list.map { |c| c.split(' ') }
        return if entries.empty?

        old_connections = []

        entries.each do |status, conn, name|
          if status != "active" and conn.to_i > 0 
            old_connections.push([name, conn.to_i])
          end
        end

        old_connections
      rescue => e 
        log.error "#{e.message}"
      end
    end

    def clean_graveyard
      graveyard = @graveyard.dup
      graves = []

      graveyard.keys.each do |url|
        graveyard[url].each do |instance|
          candidate = { :droplet_id => instance[:droplet_id], 
                        :instance_id => instance[:instance_id] }
          graves.push(candidate)
        end
      end

      stop_msg = {}
      stop_msg[:droplets] = graves

      NATS.publish('droplet.stop', Yajl::Encoder.encode(stop_msg))
    end

    def search_graveyard
      old_connections = get_old_connections
      unless old_connections 
        log.info "All connections are active states"
        clean_graveyard
        return
      end

      old_connections.each do |name, conn|
        log.info "#{name} has #{conn} connections."
      end
    end

    def check_registered_urls
      start = Time.now

      # If NATS is reconnecting, let's be optimistic and assume
      # the apps are there instead of actively pruning.
      if NATS.client.reconnecting?
        log.info "Suppressing checks on registered URLS while reconnecting to mbus."
        @droplets.each_pair do |url, instances|
          instances.each { |droplet| droplet[:timestamp] = start }
        end
        return
      end

      to_drop = []
      @droplets.each_pair do |url, instances|
        instances.each do |droplet|
          to_drop << droplet if ((start - droplet[:timestamp]) > MAX_AGE_STALE)
        end
      end
      log.debug "Checked all registered URLS in #{Time.now - start} secs."
      to_drop.each { |droplet| unregister_droplet(droplet[:url], droplet[:host], droplet[:port]) }
    end

    def lookup_droplet(url)
      @droplets[url]
    end

    def update_proxy
      update_proxy = false
      old_proxies = @proxies.dup

      unless @registered_proxy.empty? then
        fresh_proxies = @registered_proxy.dup
        @registered_proxy = {}
        fresh_proxies.keys.each do |url|
          @proxies[url] = fresh_proxies[url]
          log.info "Registering proxy #{url} at #{@proxies[url][:host]}:#{@proxies[url][:port]}"
        end
        update_proxy = true
      end

      unless @unregistered_proxy.empty? then
        dead_proxies = @unregistered_proxy.dup
        @unregistered_proxy = {}
        dead_proxies.keys.each do |url|
          @proxies.delete_if { |p| p[:url] == url }
          log.info "Unregistering proxy #{url} at #{@proxies[url][:host]}:#{@proxies[url][:port]}"
          update_proxy = true
        end
      end

      if update_proxy  || @retry then
        success = reload_haproxy(@proxies) unless @proxies.empty?

        success ? @retry = false : @retry = true
      end
    end

    # check registered queue and unregistered queue for updating varnish
    def update_droplet
      update_varnish = false
      old_droplets = @droplets.dup

      unless @registered_droplets.empty? then
        fresh_droplets = @registered_droplets.dup
        @registered_droplets = {}
        fresh_droplets.keys.each do |url| 
          droplets = @droplets[url] || [] 
          droplets += fresh_droplets[url]

          @droplets[url] = droplets
          VCAP::Component.varz[:urls] = @droplets.size
          VCAP::Component.varz[:droplets] += 1
          droplets.each do |drop|
            log.info "Registering #{url} at #{drop[:host]}:#{drop[:port]}"
          end
          log.info "#{droplets.size} servers available for #{url}"
        end        
        update_varnish = true
      end

      unless @unregistered_droplets.empty? then
        dead_droplets = @unregistered_droplets.dup
        @graveyard << @unregistered_droplets.dup

        @unregistered_droplets = {}
        dead_droplets.keys.each do |url|
          droplets = @droplets[url] || []  
          dsize = droplets.size
          dead_droplets[url].each do |drop|
            droplets.delete_if { |d| d[:host] == drop[:host] && d[:port] == drop[:port] }
          end
          @droplets.delete(url) if droplets.empty?
          VCAP::Component.varz[:urls] = @droplets.size
          VCAP::Component.varz[:droplets] -= 1 unless (dsize == droplets.size)
          log.info "#{droplets.size} servers available for #{url}"

          update_varnish = true unless (dsize == droplets.size)     
        end
      end

      if update_varnish  || @retry then
        success = reload_varnish(@droplets) unless @droplets.empty?

        success ? @retry = false : @retry = true
      end
    end

    # make backend configuration contents
    def vcl_backends(droplets)
      backends = ""
      i = 0
      droplets.keys.each do |url|
        backend_dir = "backend" + i.to_s
        i += 1
        backends += VARNISH_DIRECTOR_RR % backend_dir
        backends += "\n"
        droplets[url].each do |hash|
          backends += VARNISH_BACKEND % [hash[:host], hash[:port]]
          backends += "\n"
        end
        backends += VARNISH_BACKEND_CLOSE
        backends += "\n"
      end
      
      backends
    end
    
    # make default configuration contents
    def vcl_default(urls, time)
      default = VARNISH_DEFAULT % time      
      c = 0
      urls.each do |url|
        default += VARNISH_DEFAULT_ELSE if c > 0
        default += VARNISH_DEFAULT_IF_HOST % [url, url, time]
        c += 1
      end
      default += VARNISH_DEFAULT_CLOSE
      
      default
    end
    
    # make applicatoin configuration contents
    def vcl_site(urls, time)
      i = 0
      urls.each do |url|
        site_file = "/etc/varnish/site-#{url}-#{time}.vcl"
        `sudo cp #{site_file} /etc/varnish/site-#{url}-old.vcl` if File.exist? site_file
        backend_dir = "backend" + i.to_s
        i += 1

        site = VARNISH_SITE_TOP % [backend_dir, backend_dir]

        site += VARNISH_SITE_X_FORWARDED_FOR unless @use_lb

        site += VARNISH_SITE_BOTTOM
        
        # if user is not root but sudoer, this script have more compatibility 
        # than file operation in ruby
        `sudo bash -c 'echo "#{site}" > "#{site_file}"'`
        # File.open(site_file, "w") do |file|        
        #   site = VARNISH_SITE % [backend_dir, backend_dir]
        #   file.puts(site)
        # end
      end
    end

    def haproxy_acl(proxies)
      acl = ""

      proxies.keys.each do |key|
        proxy = proxies[key]
        rule = [proxy[:tag], proxy[:instance_id]].join('_')
        url = [proxy[:tag], proxy[:instance_id]].join('.')
        acl += HAPROXY_ACL % [rule, url]
        acl += "\n"
      end

      return acl
    end

    def haproxy_use_backend(proxies)
      use_backend = ""

      proxies.keys.each do |key|
        proxy = proxies[key]
        backend = [proxy[:tag], proxy[:instance_id]].join
        rule = [proxy[:tag], proxy[:instance_id]].join('_')
        use_backend += HAPROXY_USE_BACKEND % [backend, rule]
        use_backend += "\n"
      end

      return use_backend
    end

    def haproxy_backend(proxies)
      backend = ""

      proxies.keys.each do |key|
        proxy = proxies[key]
        backend_id = [proxy[:tag], proxy[:instance_id]].join
        host = proxy[:host]
        port = proxy[:port]
        backend += HAPROXY_BACKEND % [backend_id, backend_id, host, port]
        backend += "\n"
      end

      return backend
    end

    def reload_haproxy(proxies)
      # we keep config files two types like -latest and -old.
      time = "latest"      
      haproxy_config = @haproxy_config + "-#{time}"
      `sudo cp #{haproxy_config} #{@haproxy_config}-old` if File.exist? haproxy_config

      acl = haproxy_acl(proxies)
      use_backend = haproxy_use_backend(proxies)
      backend = haproxy_backend(proxies)

      haproxy_config_content = HAPROXY_HEAD + acl + use_backend + HAPROXY_TAIL + backend

      `sudo bash -c 'echo "#{haproxy_config_content}" > "#{haproxy_config}"'`

      result = `sudo #{@haproxy_file} -f #{haproxy_config} \
                -p /var/run/haproxy.pid \
                -sf $(cat /var/run/haproxy.pid) 2> /dev/stdout`

      return false unless result.empty?

      log.info "haproxy is restarted."
      return true
    end

    # varnish config file is composed as default.vcl, site-app_url.vcl and backend.vcl
    # default.vcl have conditional statements for url based redirecting.
    # site-app.vcl have a configuration depend on application
    # backend.vcl have droplet ip and port as directive
    # default.vcl include site and backend configuration files 
    def reload_varnish(droplets)
      epoch = Time.now.to_i.to_s

      # we keep config files two types like -latest and -old.
      time = "latest"      
      backends_file = "/etc/varnish/backends-#{time}.vcl"
      `sudo cp #{backends_file} /etc/varnish/backends-old.vcl` if File.exist? backends_file

      b_droplets = vcl_backends(droplets)

      # if user is not root but sudoer, this script have more compatibility 
      # than file operation in ruby
      `sudo bash -c 'echo "#{b_droplets}" > "#{backends_file}"'`

      # File.open(backends_file, "w") do |file|
      #   file.puts(vcl_backends(droplets))
      # end
        
      vcl_site(droplets.keys, time)
      
      default_file = "/etc/varnish/default-#{time}.vcl"
      `sudo cp #{default_file} /etc/varnish/default-old.vcl` if File.exist? default_file

      default_content = vcl_default(droplets.keys, time)

      # if user is not root but sudoer, this script have more compatibility 
      # than file operation in ruby
      `sudo bash -c 'echo "#{default_content}" > "#{default_file}"'`
      
      # File.open(default_file, "w") do |file|
      #   file.puts(_default(droplets.keys, time))
      # end        
      
      # load a generated varnish config file to varnish server by varnishadm
      result = `varnishadm -T 127.0.0.1:2000 vcl.load reload-#{epoch} #{default_file} 2> /dev/stdout`
      return false if result.match(/VCL compiled./).nil?
      
      # use new varnish config setting for varnish server
      `varnishadm -T 127.0.0.1:2000 vcl.use reload-#{epoch}`
      `varnishadm -T 127.0.0.1:2000 vcl.list`      
      log.info result
      
      return true
    end

    def register_proxy(url, host, port, instance_id, tag)
      return unless host && port
      url.downcase!
      proxy = @proxies[url] || {}

      if(proxy[:host] == host && proxy[:port] == port)
        proxy[:timestamp] = Time.now
        return
      end

      proxy = @registered_proxy[url] || {}
      proxy = {
        :host => host,
        :port => port,
        :url => url,
        :timestamp => Time.now,
        :instance_id => instance_id,
        :tag => tag
      }

      @registered_proxy[url] = proxy
    end

    def unregister_proxy(url, host, port)
      url.downcase!
      
      proxy = {
        :host => host,
        :port => port,
        :url => url,
        :timestamp => Time.now
      }

      @unregistered_proxy[url] = proxy
    end

    def register_droplet(url, host, port, tags)
      return unless host && port
      url.downcase!
      droplets = @droplets[url] || []
      # Skip the ones we already know about..
      droplets.each { |droplet|
        # If we already now about them just update the timestamp..
        if(droplet[:host] == host && droplet[:port] == port)
          droplet[:timestamp] = Time.now
          return
        end
      }

      droplets = @registered_droplets[url] || []
      droplets.each { |droplet|
        # If we already now about them just update the timestamp..
        if(droplet[:host] == host && droplet[:port] == port)
          droplet[:timestamp] = Time.now
          return
        end
      }      
      tags.delete_if { |key, value| key.nil? || value.nil? } if tags
      droplet = {
        :host => host,
        :port => port,
        :clients => Hash.new(0),
        :url => url,
        :timestamp => Time.now,
        :tags => tags
      }
      droplets << droplet

      # Add registered droplets to candidates queue
      @registered_droplets[url] = droplets
    end

    def unregister_droplet(url, host, port, instid, appid)
      log.info "Unregistering #{url} for host #{host}:#{port}"
      url.downcase!

      droplets = @unregistered_droplets[url] || []

      droplet = {
        :host => host,
        :port => port,
        :url => url,
        :instance_id => instid,
        :droplet_id => appid
      }

      droplets << droplet

      # Add unregistered droplets to candidates queue
      @unregistered_droplets[url] = droplets
    end
  end
end
