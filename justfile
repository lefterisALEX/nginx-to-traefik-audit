# proxy-connect-timeout curl helpers (homelabs k3s)
#
# Usage:
#   just nginx      # curl ingress-nginx
#   just traefik    # curl Traefik (ingress-nginx provider)
#   just all        # both, sequentially
#   just both       # both, in parallel
#
# Override targets:
#   NODE=100.110.223.52 NGINX_PORT=30244 TRAEFIK_PORT=30153 MAX_TIME=60 just all

node         := env_var_or_default("NODE",         "100.110.223.52")
nginx_port   := env_var_or_default("NGINX_PORT",   "30244")
traefik_port := env_var_or_default("TRAEFIK_PORT", "30153")
max_time     := env_var_or_default("MAX_TIME",     "60")

default: all

# curl ingress-nginx
nginx:
    curl -s -o /dev/null -w 'nginx   http=%{http_code} time=%{time_total}s\n' --max-time {{max_time}} -H 'Host: nginx-connect.example.com' http://{{node}}:{{nginx_port}}/

# curl traefik (ingress-nginx provider)
traefik:
    curl -s -o /dev/null -w 'traefik http=%{http_code} time=%{time_total}s\n' --max-time {{max_time}} -H 'Host: traefik-connect.example.com' http://{{node}}:{{traefik_port}}/

# both, sequentially
all: nginx traefik

# both, in parallel
both:
    just --parallel nginx traefik
