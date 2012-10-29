require 'optparse'
require 'fileutils'
require 'yaml'
require 'rubygems'
require 'bundler/setup'
require 'nats/client'

require 'vcap/common'
require 'vcap/component'
require 'vcap/logging'
require 'vcap/rolling_metric'

$:.unshift(File.dirname(__FILE__))

require 'router/const'
require 'router/router'
require 'router/utils'

config_path = File.join(File.dirname(__FILE__), '../config')
config_file = File.join(config_path, 'router.yml')

haproxy_path = File.join(File.dirname(__FILE__), '../ext')
haproxy_file = File.join(haproxy_path, 'haproxy')
haproxy_config = File.join(haproxy_path, 'tcp-proxy.cfg')

latest_droplets = ""

options = OptionParser.new do |opts|
  opts.banner = "Usage: router [OPTIONS]"
  opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
    config_file = opt
  end
  opts.on("-h", "--help", "Help") do
    puts opts
    exit
  end
end
options.parse!(ARGV.dup)

begin
  config = File.open(config_file) do |f|
    YAML.load(f)
  end
rescue => e
  puts "Could not read configuration file:  #{e}"
  exit
end

# install and start varnish server
begin
  # router should be run by root
  whoami = `whoami`.chomp

  sudoer = `cat /etc/group | grep admin`
  sudo = "sudo"
  if whoami == 'root' then
    sudo = ""
  elsif sudoer.match(whoami).nil? then
    puts("You should run router who have a sudoer or root.(You are #{whoami})")
    exit
  else
    sudo = "sudo"    
  end

  # check varnish is installed in the host
  varnish_which = `which varnishd`
  if varnish_which.match(/varnishd/).nil? then
    # install varnish using apt-get (only ubuntu is supported)
    print "Update apt source list...\n"
    add_key = `curl http://repo.varnish-cache.org/debian/GPG-key.txt | sudo apt-key add - && sudo bash -c 'echo "deb http://repo.varnish-cache.org/ubuntu/ lucid varnish-3.0" >> /etc/apt/sources.list'`
    update = `#{sudo} apt-get update` 
    print "Install varnish server...\n"
    install = `#{sudo} apt-get install -y varnish`
    `#{sudo} pkill varnishd`
  end

  # check if varnish is already running
  # if it is not, start varnish server
  pid = `ps -ef | grep [v]arnishd`
  if pid.match(/varnishd/).nil? then
    admin_console = "-T 127.0.0.1:2000"
    varnish_config_file = "-f /etc/varnish/default.vcl"
    threads = "-w 100,2500,120"
    cache_store = "-s malloc,2G"

    varnish_command = "#{sudo} varnishd \ 
                        #{admin_console} \
                        #{varnish_config_file} \
                        #{threads} \
                        #{cache_store}"

    ulimit_n = "#{sudo} bash -c 'ulimit -n 131072'"
    ulimit_l = "#{sudo} bash -c 'ulimit -l 82000'"
    
    # set nofile and memlock
    `#{ulimit_n}`
    `#{ulimit_l}`

    print "Starting varnish server...\n"
    `#{varnish_command}`

    pid = `ps -ef | grep [v]arnishd`    
    if pid.empty? then
      `#{varnish_command}`
      pid = `ps -ef | grep [v]arnishd`    
      if pid.empty? then
        puts("Varnish server is failed to start.")
        exit
      end
    end
    print "done.\n"
  end
rescue => e
  puts "#{e.message}"
  exit
end

# Placeholder for Component reporting
config['config_file'] = File.expand_path(config_file)
config['haproxy_file'] = File.expand_path(haproxy_file)
config['haproxy_config'] = File.expand_path(haproxy_config)

EM.epoll

EM.run do

  trap("TERM") { stop(config['pid']) }
  trap("INT")  { stop(config['pid']) }

  Router.config(config)
  Router.log.info "Starting VCAP Router (#{Router.version})"

  EM.set_descriptor_table_size(32768) # Requires Root privileges
  Router.log.info "Socket Limit:#{EM.set_descriptor_table_size}"

  create_pid_file(config['pid'])

  NATS.on_error do |e|
    if e.kind_of? NATS::ConnectError
      Router.log.error("EXITING! NATS connection failed: #{e}")
    exit!
  else
    Router.log.error("NATS problem, #{e}")
  end
  end

  NATS.start(:debug => false, :pedantic => false, :verbose => false, :reconnect => true, :max_reconnect_attempts => MAX_RECONNECT_ATTEMPTS, :reconnect_time_wait => RECONNECT_TIME_WAIT, :uri => config['mbus'])

  # Create the register/unregister listeners.
  Router.setup_listeners

  # Register ourselves with the system
  status_config = config['status'] || {}
  VCAP::Component.register(:type => 'Router',
                           :host => VCAP.local_ip(config['local_route']),
                           :index => config['index'],
                           :config => config,
                           :password => status_config['password'],
                           :logger => Router.log)

  # Setup some of our varzs..
  VCAP::Component.varz[:urls] = 0
  VCAP::Component.varz[:droplets] = 0

  VCAP::Component.varz[:tags] = {}

  @router_id = VCAP.secure_uuid
  @hello_message = { :id => @router_id, :version => Router::VERSION }.to_json.freeze

  # This will check on the state of the registered urls, do maintenance, etc..
  Router.setup_sweepers

  # This will check registered/unregistered droplets for routing
  Router.setup_updater

  # Setup a start sweeper to make sure we have a consistent view of the world.
  EM.next_tick do
    # Announce our existence
    NATS.publish('router.start', @hello_message)

    # Don't let the messages pile up if we are in a reconnecting state
    EM.add_periodic_timer(START_SWEEPER) do
      unless NATS.client.reconnecting?
        NATS.publish('router.start', @hello_message)
      end
    end
  end

end
