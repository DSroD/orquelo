# Orquelo

Live polls for PDF lectures, self-hosted. A presenter uploads a PDF deck, adds polls and runs a session: the
projector shows the slide and revealed results, and students vote from their phones. Optional Q&A gives
presenters a private question inbox and control over which question appears on screen. One deck can be reused
across classes, since every URL is scoped to a lecture session. Votes and questions are kept in Postgres for
later analysis.

Racket backend, Svelte frontend, built with Nix.

## Why

This project was initially created for my programming course, which closely follows the
[How to Design Programs](https://htdp.org/) book. I decided to write it in Racket to show my students that not
all software out there has to be in C/C++, Python or Java (as some of them firmly believe).

## Hosted version

Don't want to run it yourself? A hosted Orquelo with paid tiers runs at [orquelo.com](https://orquelo.com), on my
own infrastructure. It is built on this open-source core.

## Deploy with Docker Compose

Save the following as `compose.yaml`, or use the [included Compose file](compose.yaml).
It runs Orquelo and PostgreSQL with separate persistent volumes for PDFs and database records.

```yaml
services:
  db:
    image: postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_USER: orquelo
      POSTGRES_PASSWORD: orquelo
      POSTGRES_DB: orquelo
    volumes:
      - db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "orquelo"]
      interval: 2s
      retries: 30

  orquelo:
    image: ${ORQUELO_IMAGE:-ghcr.io/dsrod/orquelo:latest}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgresql://orquelo:orquelo@db:5432/orquelo
      PUBLIC_BASE_URL: ${PUBLIC_BASE_URL:-http://localhost:8080}
      SESSION_SECRET: ${SESSION_SECRET:?set SESSION_SECRET in .env}
      UPLOAD_DIR: /data
    volumes:
      - data:/data

volumes:
  db:
  data:
```

From the directory containing `compose.yaml`, start the services and create a presenter account.
The account command reads your chosen password from `password.txt`.

```sh
export SESSION_SECRET="$(openssl rand -base64 48)"
docker compose up -d
docker compose exec -T orquelo /bin/orquelo user add you@example.org < password.txt
```

Sign in at [localhost:8080/login](http://localhost:8080/login). Students can join a session without an account.

For a persistent deployment, save the generated `SESSION_SECRET` in a private `.env` file beside
`compose.yaml` so it stays the same across restarts. Set `PUBLIC_BASE_URL` to your public HTTPS address
and put Orquelo behind a TLS reverse proxy. If the proxy sets `X-Forwarded-For` and all traffic reaches
Orquelo through it, set `TRUST_PROXY` to `"1"` in the Orquelo service environment.
See the [configuration example](.env.example) and [account guide](docs/accounts.md).

## Build the Docker image

On Linux with Nix flakes enabled, run these commands from the repository root.

```sh
nix build .#image
docker load < result
```

On macOS, run `scripts/build-image-in-docker` with Docker running. It builds the Linux image and loads it
into Docker. To deploy your build with the Compose file above, run `ORQUELO_IMAGE=orquelo:local docker compose up -d`.

## Licence

Copyright © 2026 Daniel Rod. Licensed under the [GNU Affero General Public License, version 3 only](LICENSE).
