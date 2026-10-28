# HTTPS for app

The app speaks plain HTTP on the address in `.env` (`ADDR`). HTTPS is terminated by a
reverse proxy in front of it. This page uses NGINX with certificates from Let's Encrypt;
a complete server block is in [`deploy/nginx.conf.example`](../deploy/nginx.conf.example).
Replace `app.example.com` with your name.

## Server block

```nginx
upstream app { server 127.0.0.1:8080; keepalive 16; }

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
    add_header Strict-Transport-Security "max-age=300" always;   # raise after verifying, see below
    client_max_body_size 8m;               # the app caps bodies at 8 MiB

    location / {
        proxy_pass http://app;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

- `proxy_pass` points at the app's port (the port in `ADDR`).
- `X-Forwarded-For` carries the real client address. The app honors it only when the connection
  comes from `TRUSTED_PROXY` (see below), and then uses it for the request log and the per-IP sign-in
  limits. `TRUSTED_PROXY` governs `X-Forwarded-For` only.
- `Host` and `X-Forwarded-Proto` are ordinary proxy hygiene (correct upstream logs, and anything you add
  later that needs them); the app itself does not read them. It never builds origins from request
  headers: the same-origin check uses `PUBLIC_ORIGIN`.
- HSTS (`Strict-Transport-Security`) is set by the proxy, never by the app: app sends no HSTS header
  at all, so the proxy's value is the only one browsers see. HSTS is remembered by browsers, so roll it
  out in stages. The example ships `max-age=300` (five minutes). After you have checked that every page
  works over HTTPS, raise it (for example to `86400`, then `31536000`) and reload NGINX. If you use a
  hosting panel proxy instead, turn HSTS on there (or accept that there is none); the app will not add it.

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
TRUSTED_PROXY=127.0.0.1/32
SESSION_SECRET=<generate: openssl rand -hex 32>
```

- `PUBLIC_ORIGIN` is the origin users type: scheme and host (and a port only if it is not the default),
  nothing else. The same-origin check on state-changing requests compares the browser's `Origin` header
  against it. The app normalizes it at startup (lowercase, a trailing `/` and a default `:443`/`:80` are
  dropped) and refuses to start when it has a path, query, fragment, user info or a scheme other than
  `http`/`https`, so `https://app.example.com/app` is an error rather than a site where every sign-in is
  refused with 403.
- `SECURE_COOKIES` marks the session cookie Secure so browsers send it only over HTTPS. It defaults to
  `true` when `APP_ENV=production`, so it needs no line; set it to `false` only for a plain-HTTP test.
- `ADDR`: with NGINX on the same host use `ADDR=127.0.0.1:8080`, so the app is reachable only through
  NGINX and plain HTTP is never exposed (a `0.0.0.0` listener would let anyone bypass TLS and HSTS by
  using the port directly).
- `TRUSTED_PROXY` is the address (CIDR) the proxy connects from. `X-Forwarded-For` is trusted only from
  there; leave it empty to trust no one (then per-IP limits key on the proxy's address). With NGINX on
  the same machine connecting to `127.0.0.1`, use `127.0.0.1/32`. For a hosting panel proxy see below.
- Production refuses to start without `SESSION_SECRET` and `PUBLIC_ORIGIN`.

## Hosts with a panel proxy (HTTP/1.0)

Some hosting panels put their own proxy in front of the app and speak HTTP/1.0 to it. Such proxies
corrupt chunked or streamed static files. app serves its static assets with a known `Content-Length`
(no streaming compression), which is what these proxies need. `scripts/smoke.sh` checks this: it fetches
`/static/style.css` with `curl --http1.0 --compressed` and requires the bytes to equal the local file.
A panel proxy that reaches the app through the host's public address needs `ADDR=0.0.0.0:<port>` (a
loopback-only app shows as 502 there) and `TRUSTED_PROXY=<the proxy's address>/32` instead of
`127.0.0.1/32`; see "Configure `.env`" in [deploy.md](deploy.md) for how to find that address. Where the panel manages the proxy and certificates, do not
add a second proxy file by hand: use one or the other.

## Variant: system-wide service (hosts with root)

With root you can run app as a system service instead of a user service, and NGINX on the same
host proxies to `127.0.0.1`:

```ini
# /etc/systemd/system/app.service
[Unit]
Description=app
After=network.target

[Service]
User=app
Group=app
ExecStart=/opt/app/current/app serve
WorkingDirectory=/opt/app/data
EnvironmentFile=/opt/app/.env
Environment=DATA_DIR=/opt/app/data
UMask=0077
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/app/data
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

Use `ADDR=127.0.0.1:8080` in `.env` so only NGINX can reach the app, enable it with
`sudo systemctl enable --now app`, and adapt `deploy.sh` (`REMOTE_BASE`, `SERVICE`) and the systemctl
calls, which use `systemctl --user`, to your layout. No linger is needed for a system service.
