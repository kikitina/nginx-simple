# nginx-simple

This repo runs a minimal `nginx` container on port `8888` with a `204` response on `/generate_204`.

## One-line Ubuntu setup

Download the bootstrap script and execute it in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/kikitina/nginx-simple/main/setup-nginx.sh -o setup-nginx.sh && bash setup-nginx.sh
```

The script will:

- install Docker Engine on Ubuntu with Docker's official `apt` repository if Docker is missing
- start the Docker service if needed
- download this repo's compose and nginx config when the script is run standalone
- launch the nginx container with `docker compose up -d`

After it completes, verify the server:

```bash
curl -i http://localhost:8888/generate_204
```

If you already cloned the repo, run the same bootstrap locally from the repo root:

```bash
bash setup-nginx.sh
```
