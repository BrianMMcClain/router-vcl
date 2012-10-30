
# Timers for varnish
VARNISH_RELOAD = 10
# Timers for haproxy
HAPROXY_RELOAD = 10
# Timers for cleanup graveyard
GRAVEYARD_CLEAN = 30

# Reconnect count
RECONNECT_TIME_WAIT = 5
MAX_RECONNECT_ATTEMPTS = 100

CHECK_SWEEPER = 30
MAX_AGE_STALE = 120
START_SWEEPER = 30

VARNISH_DEFAULT = 'import std;

include \"/etc/varnish/backends-%s.vcl\";

sub vcl_recv {
  if (! req.http.Host)
  {
          error 404 \"Need a host header\";
  }
  set req.http.Host = regsub(req.http.Host, \"^www\\.\", \"\");
  set req.http.Host = regsub(req.http.Host, \":80$\", \"\");
'
VARNISH_DEFAULT_ELSE = 'els'

VARNISH_DEFAULT_IF_HOST = 'if (req.http.Host == \"%s\")
{
  include \"/etc/varnish/site-%s-%s.vcl\";
}'

VARNISH_DEFAULT_CLOSE = '}'

VARNISH_DIRECTOR_RR = 'director %s round-robin {'

VARNISH_BACKEND = '{ .backend = { .host = \"%s\"; .port = \"%s\"; .probe = { .url = \"/\"; .interval = 5s; .timeout = 5s; .window = 5; .threshold = 3; }  } }'

VARNISH_BACKEND_CLOSE = '}'

VARNISH_SITE_TOP = '# VCL for multiple backend site with HA
  # Define the director that determines how to distribute incoming requests.
  # set the round-robin director
  set req.backend = %s; 

  # Use anonymous, cached pages if all backends are down.
  if (!req.backend.healthy) {
  set req.backend = %s; 
  }

  # Allow the backend to serve up stale content if it is responding slowly.
  set req.grace = 6h;
  '

VARNISH_SITE_X_FORWARDED_FOR = '
  # Add a unique header containing the client address
  remove req.http.X-Forwarded-For;
  set    req.http.X-Forwarded-For = client.ip;
'

VARNISH_SITE_BOTTOM = '
  if (req.request != \"GET\" &&
    req.request != \"HEAD\" &&
    req.request != \"PUT\" &&
    req.request != \"POST\" &&
    req.request != \"TRACE\" &&
    req.request != \"OPTIONS\" &&
    req.request != \"DELETE\") {
    /* Non-RFC2616 or CONNECT which is weird. */
    return (pipe);
  }
  if (req.request != \"GET\" && req.request != \"HEAD\") {
    /* We only deal with GET and HEAD by default */
    return (pass);
  }
  if (req.http.Authorization || req.http.Cookie) {
    /* Not cacheable by default */
    return (pass);
  }
  
  # Pipe websocket connections to application
  if (req.http.Upgrade ~ \"(?i)websocket\") {
    return (pipe);
  }

  return (lookup);  '

HAPROXY_HEAD = '
global
  log        localhost local0 err
  maxconn    65534
  daemon
  quiet

frontend tcp-in
  bind       :9001
  mode       tcp
  log        global
  clitimeout 30000
  option     dontlognull
  maxconn    65534
'
HAPROXY_TAIL = '
  default_backend debug_default

backend debug_default
  mode tcp
  server debug_default localhost:80
'
HAPROXY_ACL = 'acl %s hdr_beg(host) -i %s'

HAPROXY_USE_BACKEND = 'use_backend %s if %s'

HAPROXY_BACKEND = 'backend %s
  mode tcp
  server %s %s:%s maxconn 60000
'
