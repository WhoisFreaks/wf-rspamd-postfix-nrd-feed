# /etc/rspamd/local.d/worker-proxy.inc
#
# Enables the Rspamd milter proxy worker so Postfix can connect to
# Rspamd over a local TCP socket on port 11332.

bind_socket = "localhost:11332";
milter      = yes;

upstream "local" {
  default   = yes;
  self_scan = yes;
}
