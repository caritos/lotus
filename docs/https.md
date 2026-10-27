# HTTPS for goweb

The app speaks plain HTTP on the address in `.env` (`ADDR`). HTTPS is terminated by a
reverse proxy in front of it. This page uses NGINX with certificates from Let's Encrypt;
a complete server block is in [`deploy/nginx.conf.example`](../deploy/nginx.conf.example).
Replace `app.example.com` with your name.

## Server block

```nginx
upstream goweb { server 127.0.0.1:8080; keepalive 16; }

server {                                   # HTTP: certificate challenges, then redirect
    listen 80;
    server_name app.example.com;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    http2 on;
    server_name app.example.com;
    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;
    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 8m;               # the app caps bodies at 8 MiB

    location / {
        proxy_pass http://goweb;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

- `proxy_pass` points at the app's port (the port in `ADDR`).
- `Host`, `X-Forwarded-For` and `X-Forwarded-Proto` let the app log real client addresses and
  build correct origins.
- Add HSTS (`Strict-Transport-Security`) only once HTTPS works for every page: browsers remember it. Start
  with a short `max-age` (for example 300) while testing, then raise it.

## Certificates with certbot

1. Point the DNS `A` (and `AAAA`) record of `app.example.com` at the server.
2. Install the HTTP-only server block first (the port 80 block above, without the 443 block) and reload NGINX.
3. Issue the certificate:
   ```sh
   sudo certbot certonly --webroot -w /var/www/certbot -d app.example.com
   ```
4. Add the 443 block, run `sudo nginx -t && sudo systemctl reload nginx`.
5. Renewal is automatic through the certbot timer. Check it with
   `sudo certbot renew --dry-run`, and make certbot reload NGINX after renewal
   (`--deploy-hook 'systemctl reload nginx'`).

Check the result: `curl -sI http://app.example.com/` is a `301` to the https URL, and
`curl -sI https://app.example.com/healthz` is `200`.

## Matching `.env` values

The app must know it is behind HTTPS and which proxy to trust:

```
APP_ENV=production
PUBLIC_ORIGIN=https://app.example.com
SECURE_COOKIES=true
TRUSTED_PROXY=127.0.0.1/32
SESSION_SECRET=<generate: openssl rand -hex 32>
```

- `PUBLIC_ORIGIN` must equal the origin users type, scheme included; the same-origin check on
  state-changing requests compares against it.
- `SECURE_COOKIES=true` marks the session cookie Secure so browsers send it only over HTTPS.
- `TRUSTED_PROXY` is the address (CIDR) the proxy connects from. `X-Forwarded-For` is trusted only from
  there; leave it empty to trust no one. When the proxy runs on the same machine and connects to `127.0.0.1`,
  use `127.0.0.1/32`.
- Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`.

## Hosts with a panel proxy (HTTP/1.0)

Some hosting panels put their own proxy in front of the app and speak HTTP/1.0 to it. Such proxies
corrupt chunked or streamed static files. goweb serves its static assets with a known `Content-Length`
(no streaming compression), which is what these proxies need. `deploy/smoke.sh` checks this: it fetches
`/static/style.css` with `curl --http1.0 --compressed` and requires the bytes to equal the local file.
Also listen on `0.0.0.0` in `ADDR` for panel proxies, which reach the app through the host's public
address; a loopback-only app shows as 502 there. Where the panel manages the proxy and certificates, do not
add a second proxy file by hand: use one or the other.

## Variant: system-wide service (hosts with root)

With root you can run goweb as a system service instead of a user service, and NGINX on the same
host proxies to `127.0.0.1`:

```ini
# /etc/systemd/system/goweb.service
[Unit]
Description=goweb
After=network.target

[Service]
User=goweb
Group=goweb
ExecStart=/opt/goweb/current/goweb serve
WorkingDirectory=/opt/goweb/data
EnvironmentFile=/opt/goweb/.env
Environment=DATA_DIR=/opt/goweb/data
UMask=0077
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/goweb/data
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

Use `ADDR=127.0.0.1:8080` in `.env` so only NGINX can reach the app, enable it with
`sudo systemctl enable --now goweb`, and adapt `deploy.sh` (`REMOTE_BASE`, `SERVICE`) and the systemctl
calls, which use `systemctl --user`, to your layout. No linger is needed for a system service.
